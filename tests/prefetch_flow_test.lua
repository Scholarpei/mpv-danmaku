-- prefetch 集成测试：maybe_prefetch 触发门槛与执行链路（自断言，输出 PASS/FAIL 行）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败
-- 覆盖：触发门槛（auto_load/缓存/协议路径/无下一项/异文件夹/无记忆）/
--   全链路预取三类任务入缓存（ep:/ext:/cid:）与正式加载同键 /
--   TTL 命中零网络 / armed 每文件仅评估一次 / bilibili_series_memory=off 剪裁 / 断网静默不崩

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local utils = require("mp.utils")

local PLATFORM = mp.get_property_native("platform")
    or (os.getenv("windir") ~= nil and "windows" or "linux")

local TMP = (os.getenv("TEMP") or "/tmp")
    .. "/prefetch_flow_test_" .. tostring(os.time()) .. "_"
    .. tostring(utils.getpid and utils.getpid() or 0)
mp.command_native({ name = "subprocess", playback_only = false,
    args = PLATFORM == "windows"
        and { "cmd", "/c", "mkdir", (TMP:gsub("/", "\\")) }
        or { "mkdir", "-p", TMP } })

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

-- ---- 打桩（须在 require 模块前；运行时按全局查找这些名字）----
show_message = function() end
load_danmaku = function(from_menu) end
DANMAKU = { sources = {}, count = 1 }

-- mp 属性桩：normalize 探测 command-list 返回空表 → 走 working-directory 拼接分支（不发子进程）
local real_get_property = mp.get_property
local real_get_property_native = mp.get_property_native
local STUB = {
    path = TMP .. "/Show - 08.mkv",
    fname = "Show - 08",
    next_path = TMP .. "/Show - 09.mkv",
    pos = 0,
    count = 2,
}
mp.get_property = function(name, default)
    if name == "path" then return STUB.path end
    if name == "filename/no-ext" then return STUB.fname end
    if name == "working-directory" then return "" end
    if name:match("^playlist/%d+/filename$") then return STUB.next_path end
    return default
end
mp.get_property_number = function(name, default)
    if name == "playlist-playing-pos" then return STUB.pos end
    if name == "playlist-count" then return STUB.count end
    return default
end
mp.get_property_native = function(name, default)
    if name == "command-list" then return {} end
    return real_get_property_native(name, default)
end

require("modules/options")
options.auto_load = true
options.api_server = "https://api.example.com"
require("modules/utils")

-- 网络桩：按 URL 尾参分发预置响应；计数供命中/跳过断言
local BILI_XML = '<?xml version="1.0" encoding="UTF-8"?><i>'
    .. '<d p="1.000,1,25,16777215,1,0,0,0">hi</d>'
    .. '<d p="2.000,4,25,9830415,1,0,0,0">yo</d></i>'
local net = { calls = {}, fail_all = false }
call_cmd_async = function(args, cb)
    local url
    for i = #args, 1, -1 do
        local v = args[i]
        if type(v) == "string" and v:find("^https?://") then url = v break end
    end
    net.calls[#net.calls + 1] = url or "?"
    mp.add_timeout(0.01, function()
        if net.fail_all or url == nil then
            cb("curl: (7) Failed to connect", nil)
            return
        end
        if url:find("/api/v2/extcomment") then
            cb(nil, '{"count":1,"comments":[{"p":"3.00,1,16777215","m":"ext"}]}')
        elseif url:find("/api/v2/comment/") then
            cb(nil, '{"count":2,"comments":[{"p":"1.00,1,16777215","m":"a"},'
                .. '{"p":"2.00,4,9830415","m":"b"}]}')
        elseif url:find("comment%.bilibili%.com/") then
            cb(nil, BILI_XML)
        else
            cb("unexpected url: " .. tostring(url), nil)
        end
    end)
    return function() end
end

local function count_url(pattern)
    local n = 0
    for _, u in ipairs(net.calls) do
        if u:find(pattern, 1, false) then n = n + 1 end
    end
    return n
end

Sha256 = require("modules/hash")
require("modules/parse")
require("modules/guess")  -- get_episode_number → get_series_episodes 依赖 format_filename
require("apis/dandanplay")
require("sites/bilibili")

-- B站分P列表桩：20 页、cid=9000+page（预取与匹配真实链路，仅桩列表接口）
fetch_bilibili_pagelist = function(vid, cb)
    local pages = {}
    for i = 1, 20 do
        pages[i] = { page = i, part = tostring(i), duration = 1420, cid = 9000 + i }
    end
    mp.add_timeout(0.01, function() cb(pages) end)
end

-- 腾讯 resolver 桩：目标集数 → 规范 URL（URL 形态与 resume 路径一致）
resolve_tencent_episode_url = function(extra, episodenum, cb)
    mp.add_timeout(0.01, function()
        cb("https://v.qq.com/x/cover/c1/v" .. episodenum .. ".html")
    end)
end

local dc = require("modules/danmaku_cache")
dc.setup({
    enabled = true, dir = TMP, ttl_seconds = 3600, max_bytes = 0,
    platform = PLATFORM,
    run_sync = function(cmd) return mp.command_native(cmd) end,
    log = function() end,
})

local prefetch_mod = require("modules/prefetch")

-- 历史记录：键用真实 get_parent_directory 计算，规避路径规范化格式假设
local KEY_DIR = get_parent_directory(TMP .. "/Show - 08.mkv")
HISTORY_PATH = TMP .. "/history.json"
local function write_history(record)
    local h = {}
    if record then h[KEY_DIR] = record end
    write_json_file(HISTORY_PATH, h)
end

local RECORD = {
    fname = "Show - 08",
    episodeNumber = 8,
    episodeId = 100108,
    episodeId_fname = "Show - 08",
    api_server = "https://api.example.com",
    extras = {
        { kind = "qq", cid = "c1", episodenum = 8, fname = "Show - 08" },
    },
    bilibili = { BV123 = { page = 8, episode = 8, season = 1, ts = 1 } },
}

local steps = {}

-- ---------- 用例组 A：全链路（ddp + qq ext + B站合集 三类任务入缓存） ----------
-- 注意：armed 每文件仅评估一次是正式语义，故各组场景用不同文件路径互不干扰
steps[1] = function()
    write_history(RECORD)
    prefetch_mod.maybe_prefetch()
end

steps[2] = function()
    check("弹弹play ep:100109 已入缓存", dc.get("ep:100109") ~= nil)
    check("ext: 腾讯 v9 已入缓存",
        dc.get(extcomment_cache_key("https://v.qq.com/x/cover/c1/v9.html")) ~= nil)
    check("cid:9009 已入缓存", dc.get("cid:9009") ~= nil)
    check("comment API 恰好一次", count_url("/api/v2/comment/") == 1)
    check("extcomment 恰好一次", count_url("/api/v2/extcomment") == 1)
    check("B站 XML 恰好一次", count_url("comment.bilibili.com") == 1)
    -- 预取不产生任何渲染/DANMAKU 污染
    check("不写 DANMAKU.sources", next(DANMAKU.sources) == nil)
end

-- ---------- 用例组 B：armed 每文件仅评估一次 ----------
steps[3] = function()
    local before = #net.calls
    prefetch_mod.maybe_prefetch()
    prefetch_mod.maybe_prefetch()
    check("同文件重复触发不再发包", #net.calls == before)
end

-- ---------- 用例组 C：触发门槛（均零网络增量；auto_load 门槛先于 armed 不占路径） ----------
steps[4] = function()
    options.auto_load = false
    local before = #net.calls
    prefetch_mod.maybe_prefetch()
    check("auto_load 关闭不预取", #net.calls == before)
    options.auto_load = true
end

steps[5] = function()
    STUB.path = TMP .. "/Show - 06.mkv"
    STUB.fname = "Show - 06"
    STUB.next_path = TMP .. "/Show - 07.mkv"
    STUB.count = 1  -- 播放列表无下一项
    local before = #net.calls
    prefetch_mod.maybe_prefetch()
    check("无下一项不预取", #net.calls == before)
    STUB.count = 2
end

steps[6] = function()
    STUB.path = TMP .. "/Show - 05.mkv"
    STUB.fname = "Show - 05"
    STUB.next_path = (os.getenv("TEMP") or "/tmp") .. "/other/Show - 06.mkv"
    local before = #net.calls
    prefetch_mod.maybe_prefetch()
    check("下一项异文件夹不预取", #net.calls == before)
end

steps[7] = function()
    STUB.path = TMP .. "/Show - 04.mkv"
    STUB.fname = "Show - 04"
    STUB.next_path = TMP .. "/Show - 05.mkv"
    write_history(nil)  -- 文件夹无记忆
    local before = #net.calls
    prefetch_mod.maybe_prefetch()
    check("文件夹无记忆不预取", #net.calls == before)
    write_history(RECORD)
end

-- ---------- 用例组 D：TTL 命中零网络（换文件重新评估） ----------
steps[8] = function()
    -- 当前 Show - 10、下一集 Show - 11：对锚 Show - 08 差值 3 → ddp=100111、qq=11、B站=11
    STUB.path = TMP .. "/Show - 10.mkv"
    STUB.fname = "Show - 10"
    STUB.next_path = TMP .. "/Show - 11.mkv"
    dc.put("ep:100111", '{"count":1,"comments":[{"p":"1.00,1,16777215","m":"z"}]}',
        { type = "json", count = 1 })
    dc.put(extcomment_cache_key("https://v.qq.com/x/cover/c1/v11.html"),
        '{"count":1,"comments":[{"p":"1.00,1,16777215","m":"z"}]}', { type = "json", count = 1 })
    dc.put("cid:90011", BILI_XML, { type = "xml" })
    local before = #net.calls
    prefetch_mod.maybe_prefetch()
    check("全部缓存命中零网络", #net.calls == before)
end

-- ---------- 用例组 E：bilibili_series_memory=off 剪裁 B站任务 ----------
steps[9] = function()
    -- 当前 Show - 12、下一集 Show - 13：差值 5 → ddp=100113、qq=13(v13)、B站=13(off 剪裁)
    STUB.path = TMP .. "/Show - 12.mkv"
    STUB.fname = "Show - 12"
    STUB.next_path = TMP .. "/Show - 13.mkv"
    options.bilibili_series_memory = "off"
    prefetch_mod.maybe_prefetch()
end

steps[10] = function()
    check("off 时 B站合集不预取", dc.get("cid:90013") == nil)
    check("off 时其余源照常预取", dc.get("ep:100113") ~= nil
        and dc.get(extcomment_cache_key("https://v.qq.com/x/cover/c1/v13.html")) ~= nil)
    options.bilibili_series_memory = "add"
end

-- ---------- 用例组 F：断网全败静默不崩（换集时照常走网络） ----------
steps[11] = function()
    -- 当前 Show - 14、下一集 Show - 15：差值 7 → ddp=100115、qq=15(v15)
    STUB.path = TMP .. "/Show - 14.mkv"
    STUB.fname = "Show - 14"
    STUB.next_path = TMP .. "/Show - 15.mkv"
    net.fail_all = true
    prefetch_mod.maybe_prefetch()
end

steps[12] = function()
    check("断网不写缓存", dc.get("ep:100115") == nil
        and dc.get(extcomment_cache_key("https://v.qq.com/x/cover/c1/v15.html")) == nil)
    check("断网不产生 DANMAKU 污染", next(DANMAKU.sources) == nil)
    net.fail_all = false
end

local function rmdir(path)
    mp.command_native({ name = "subprocess", playback_only = false,
        args = PLATFORM == "windows"
            and { "cmd", "/c", "rmdir", (path:gsub("/", "\\")) }
            or { "rmdir", path } })
end

local function finish()
    dc.clear()
    os.remove(HISTORY_PATH)
    rmdir(TMP)
    print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
    -- os.exit 直杀：mpv 正常 quit 的关机路径在 Windows 控制台代理下偶发挂起（测试环境已知问题）
    os.exit(failures > 0 and 1 or 0)
end

local function run(i)
    local s = steps[i]
    if not s then
        finish()
        return
    end
    mp.add_timeout(0.3, function()
        s()
        run(i + 1)
    end)
end

run(1)
