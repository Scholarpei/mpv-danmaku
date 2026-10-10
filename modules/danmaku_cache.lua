-- 弹幕磁盘缓存（按 episodeId/cid 键值落盘，带 TTL 与容量淘汰）
-- 纯 Lua 模块：不依赖全局 options/DANMAKU，配置经 setup 注入以便单元测试；
-- 仅 require mp.utils（mpv 宿主与测试 runner——mpv 本身——均提供）。调用方 main.lua
--
-- 缓存文件格式：首行 JSON meta（v/ts/type/count）+ 换行 + 原始载荷，单文件单键。
-- 载荷原样交回调用方既有的解析路径（parse_json / parse_xml_danmaku），下游零改动。
-- 键名约定：弹弹play "ep:{episodeId}"、B站 "cid:{cid}"（纯数字，无碰撞）。
--
-- 语义：
--   get       —— TTL 内命中才返回；过期不删文件（留给 get_stale 断网兜底），返回 nil 走网络刷新
--   get_stale —— 不检 TTL，仅网络失败回退用（断网可看）
--   put       —— 直写非原子（与 history JSON 同款既有模式，多 mpv 实例并发最坏单 key 损坏→miss）；
--                失败静默降级；成功后防抖触发 GC（不在启动期与加载同步路径执行）

local utils = require("mp.utils")

local M = {}

local S = {
    enabled = false,
    dir = nil,
    ttl = 0,            -- 秒；<=0 永不过期
    max_bytes = 0,      -- <=0 不限量
    platform = "linux",
    now = os.time,
    run_sync = nil,     -- function(cmd_table) -> result（main.lua 注入 mp.command_native）
    defer = nil,        -- function(delay, fn)（main.lua 注入 mp.add_timeout；缺省同步执行，供测试确定性）
    log = function() end,
    last_gc = 0,
    writes_since_gc = 0,
}

local GC_INTERVAL = 600      -- 距上次 GC 超过该秒数才允许再触发
local GC_WRITES = 4          -- 或累计写入达到该次数才触发

-- 键名 -> 文件名：非安全字符统一折叠为 _（ep:1001 -> ep_1001.dcache）
local function cache_path(key)
    local name = tostring(key):gsub(":", "_"):gsub("[^%w%-_%.]", "_")
    return S.dir .. "/" .. name .. ".dcache"
end

-- 确保缓存目录存在（模块内唯一 subprocess 触点，经 run_sync 注入）
-- playback_only=false：目录初始化发生在启动期，不受播放状态影响（call_cmd_async 取数用 true）
local function ensure_dir(dir)
    local meta = utils.file_info(dir)
    if meta and meta.is_dir then return true end
    if S.run_sync then
        if S.platform == "windows" then
            -- 必须用反斜杠：cmd 的 mkdir 会把正斜杠路径段当开关解析（C:/Users → 语法错误）。
            -- 逐级创建且存在即跳过：cmd 多级 mkdir 依赖 Command Extensions，逐级更稳也更安静
            local drive = dir:match("^([A-Za-z]:)[/\\]")
            if drive then
                local cur = drive
                for seg in dir:sub(#drive + 1):gsub("[/\\]+", "\\"):gmatch("[^\\]+") do
                    cur = cur .. "\\" .. seg
                    local info = utils.file_info(cur)
                    if not (info and info.is_dir) then
                        S.run_sync({
                            name = "subprocess", playback_only = false,
                            capture_stdout = true, capture_stderr = true,
                            args = { "cmd", "/c", "mkdir", cur },
                        })
                    end
                end
            else
                -- 相对路径/UNC 兜底单次尝试（expand-path 产物正常不会走到这里）
                S.run_sync({
                    name = "subprocess", playback_only = false,
                    capture_stdout = true, capture_stderr = true,
                    args = { "cmd", "/c", "mkdir", (dir:gsub("/", "\\")) },
                })
            end
        else
            S.run_sync({
                name = "subprocess", playback_only = false,
                capture_stdout = true, capture_stderr = true,
                args = { "mkdir", "-p", dir },
            })
        end
    end
    meta = utils.file_info(dir)
    return meta ~= nil and meta.is_dir == true   -- 一律以 file_info 终验为准
end

-- 读单个缓存条目：返回 {payload=string, meta=table} 或 nil（不存在/损坏）
local function read_entry(key)
    local file = io.open(cache_path(key), "rb")
    if not file then return nil end
    local content = file:read("*all")
    file:close()
    if not content then return nil end
    local line_end = content:find("\n", 1, true)
    if not line_end then return nil end
    local meta = utils.parse_json(content:sub(1, line_end - 1))
    if type(meta) ~= "table" or type(meta.ts) ~= "number" then return nil end
    return { payload = content:sub(line_end + 1), meta = meta }
end

-- 初始化（main.lua 在 PLATFORM 检测之后调用一次；不能放模块加载期，require 先于 PLATFORM）
-- 建目录失败时静默禁用（仅 log warn，不弹 OSD），功能退化为不缓存
-- opts：enabled / dir(绝对路径) / ttl_seconds(<=0 永不过期) / max_bytes(<=0 不限) /
--       platform("windows"|"darwin"|"linux") / now(测试假时钟) / run_sync / defer / log
function M.setup(opts)
    opts = opts or {}
    S.ttl = tonumber(opts.ttl_seconds) or 0
    S.max_bytes = tonumber(opts.max_bytes) or 0
    S.platform = opts.platform or "linux"
    S.now = opts.now or os.time
    S.run_sync = opts.run_sync
    S.defer = opts.defer
    S.log = opts.log or function() end
    S.last_gc = S.now()
    S.writes_since_gc = 0
    if not opts.enabled or type(opts.dir) ~= "string" or opts.dir == "" then
        S.enabled, S.dir = false, nil
        return false
    end
    -- 仅接受绝对路径：相对路径会落在不可预期的 cwd（如 expand-path 异常返回空时），直接禁用
    local is_abs = opts.dir:match("^%a:[/\\]") ~= nil
        or opts.dir:sub(1, 1) == "/" or opts.dir:sub(1, 2) == "\\"
    if not is_abs then
        S.enabled, S.dir = false, nil
        S.log("warn", "弹幕缓存目录不是绝对路径，已禁用磁盘缓存：" .. opts.dir)
        return false
    end
    S.dir = opts.dir
    if not ensure_dir(S.dir) then
        S.enabled, S.dir = false, nil
        S.log("warn", "弹幕缓存目录创建失败，已禁用磁盘缓存：" .. tostring(opts.dir))
        return false
    end
    S.enabled = true
    return true
end

function M.enabled()
    return S.enabled
end

function M.get(key)
    if not S.enabled then return nil end
    local entry = read_entry(key)
    if not entry then return nil end
    if S.ttl > 0 and S.now() - entry.meta.ts >= S.ttl then
        return nil
    end
    return entry
end

function M.get_stale(key)
    if not S.enabled then return nil end
    return read_entry(key)
end

function M.put(key, payload, extra)
    if not S.enabled or not S.dir or type(payload) ~= "string" then return false end
    extra = extra or {}
    local meta = {
        v = 1,
        ts = S.now(),
        type = extra.type or "json",
        count = extra.count or 0,
    }
    local file = io.open(cache_path(key), "wb")
    if not file then return false end
    file:write(utils.format_json(meta) .. "\n" .. payload)
    file:close()
    -- 防抖 GC：距上次超过 GC_INTERVAL 或累计写入达 GC_WRITES 次才触发
    S.writes_since_gc = S.writes_since_gc + 1
    if S.max_bytes > 0
        and (S.now() - S.last_gc > GC_INTERVAL or S.writes_since_gc >= GC_WRITES) then
        S.last_gc = S.now()
        S.writes_since_gc = 0
        if S.defer then
            S.defer(0.1, function() M.gc() end)
        else
            M.gc()
        end
    end
    return true
end

function M.remove(key)
    if not S.enabled or not S.dir then return false end
    return os.remove(cache_path(key)) ~= nil
end

-- 清空全部缓存（菜单「清空弹幕缓存」），返回删除条数
function M.clear()
    if not S.enabled or not S.dir then return 0 end
    local files = utils.readdir(S.dir, "files")
    if not files then return 0 end
    local n = 0
    for _, name in ipairs(files) do
        if name:sub(-7) == ".dcache" then
            if os.remove(S.dir .. "/" .. name) then n = n + 1 end
        end
    end
    return n
end

-- 容量淘汰：总量超 max_bytes 时按 ts 升序（最旧优先）删除至达标；损坏文件 ts 视为 0 最优先清掉
function M.gc()
    if not S.enabled or not S.dir or S.max_bytes <= 0 then return end
    local files = utils.readdir(S.dir, "files")
    if not files then return end
    local entries, total = {}, 0
    for _, name in ipairs(files) do
        if name:sub(-7) == ".dcache" then
            local path = S.dir .. "/" .. name
            local info = utils.file_info(path)
            local size = (info and info.is_file and info.size) or 0
            -- 只读首 256 字节拿 ts，避免整读大载荷
            local ts = 0
            local f = io.open(path, "rb")
            if f then
                local head = f:read(256) or ""
                f:close()
                local line_end = head:find("\n", 1, true)
                if line_end then
                    local meta = utils.parse_json(head:sub(1, line_end - 1))
                    if type(meta) == "table" and type(meta.ts) == "number" then
                        ts = meta.ts
                    end
                end
            end
            entries[#entries + 1] = { path = path, size = size, ts = ts }
            total = total + size
        end
    end
    if total <= S.max_bytes then return end
    table.sort(entries, function(a, b) return a.ts < b.ts end)
    for _, e in ipairs(entries) do
        if total <= S.max_bytes then break end
        if os.remove(e.path) then
            total = total - e.size
        end
    end
end

return M
