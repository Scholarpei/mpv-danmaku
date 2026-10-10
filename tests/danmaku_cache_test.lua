-- danmaku_cache 单元测试（自断言，输出 PASS/FAIL 行）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败
-- 假时钟注入 + 不注入 defer（GC 同步执行），保证断言确定性

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local dc = require("modules/danmaku_cache")
local utils = require("mp.utils")

local PLATFORM = mp.get_property_native("platform")
    or (os.getenv("windir") ~= nil and "windows" or "linux")

local TMP = (os.getenv("TEMP") or "/tmp")
    .. "/danmaku_cache_test_" .. tostring(os.time()) .. "_"
    .. tostring(utils.getpid and utils.getpid() or 0)

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

local fake_now = 1000000
local function setup_opts(extra)
    extra = extra or {}
    return dc.setup({
        enabled = extra.enabled ~= false,
        dir = extra.dir or TMP,
        ttl_seconds = extra.ttl_seconds or 3600,
        max_bytes = extra.max_bytes or 0,
        platform = PLATFORM,
        now = function() return fake_now end,
        run_sync = extra.run_sync ~= nil and extra.run_sync
            or function(cmd) return mp.command_native(cmd) end,
        log = function() end,
    })
end

local function rmdir(path)
    if PLATFORM == "windows" then
        -- cmd 的内置命令要求反斜杠路径（正斜杠段会被当开关解析）
        mp.command_native({ name = "subprocess", playback_only = false,
            args = { "cmd", "/c", "rmdir", (path:gsub("/", "\\")) } })
    else
        mp.command_native({ name = "subprocess", playback_only = false,
            args = { "rmdir", path } })
    end
end

-- 1. setup：建目录成功并启用
check("setup 成功", setup_opts() == true and dc.enabled() == true)

-- 2. put/get 往返：多行 XML 载荷逐字节一致
local XML = '<i>\n<d p="1.00,1,25,16777215">你好\n世界</d>\n<d p="2.00,4,25,9830423">二行</d>\n</i>\n'
check("put 成功", dc.put("cid:12345678", XML, { type = "xml", count = 2 }) == true)
local hit = dc.get("cid:12345678")
check("get 命中", hit ~= nil)
check("载荷逐字节一致", hit and hit.payload == XML)
check("meta.type 保留", hit and hit.meta.type == "xml")
check("meta.count 保留", hit and hit.meta.count == 2)
check("meta.ts 为假时钟", hit and hit.meta.ts == fake_now)

-- 3. TTL：期内命中；过期 get=nil 而 get_stale 命中（断网兜底）
fake_now = fake_now + 100
check("TTL 内 get 命中", dc.get("cid:12345678") ~= nil)
fake_now = fake_now + 3501
check("过期 get 返回 nil", dc.get("cid:12345678") == nil)
check("过期 get_stale 命中", dc.get_stale("cid:12345678") ~= nil)
check("过期文件未删除（get_stale 可读）", dc.get_stale("cid:12345678").payload == XML)

-- 4. ttl=0 永不过期
setup_opts({ ttl_seconds = 0 })
dc.put("ep:1001", '{"count":1,"comments":[{}]}', { type = "json", count = 1 })
fake_now = fake_now + 999999
check("ttl=0 永不过期", dc.get("ep:1001") ~= nil)

-- 5. 不存在的键：双 nil
check("不存在键 get=nil", dc.get("ep:999999") == nil)
check("不存在键 get_stale=nil", dc.get_stale("ep:999999") == nil)

-- 6. 损坏文件（无 meta 行的垃圾）：双 nil 降级
setup_opts()
local junk = io.open(TMP .. "/ep_777.dcache", "wb")
junk:write("这不是JSON头\n" .. string.rep("垃圾", 50))
junk:close()
check("损坏文件 get=nil", dc.get("ep:777") == nil)
check("损坏文件 get_stale=nil", dc.get_stale("ep:777") == nil)

-- 7. 文件名映射：ep:1001 -> ep_1001.dcache
local names = utils.readdir(TMP, "files")
local found = false
for _, n in ipairs(names or {}) do
    if n == "ep_1001.dcache" then found = true end
end
check("文件名映射 ep:1001 -> ep_1001.dcache", found)

-- 8. remove：先 true 后 false，删后 miss
dc.put("ep:2002", "x", { type = "json", count = 1 })
check("remove 成功返回 true", dc.remove("ep:2002") == true)
check("remove 不存在返回 false", dc.remove("ep:2002") == false)
check("remove 后 miss", dc.get_stale("ep:2002") == nil)

-- 9. enabled=false：put=false / get=nil
setup_opts({ enabled = false })
check("禁用后 enabled=false", dc.enabled() == false)
check("禁用后 put=false", dc.put("ep:3003", "x", {}) == false)
check("禁用后 get=nil", dc.get("ep:3003") == nil)

-- 10. setup 建目录失败（无 run_sync 且目录不存在）：静默禁用
check("无 subprocess 且目录不存在 → setup=false",
    dc.setup({
        enabled = true,
        dir = TMP .. "/no_such_sub_dir_x",
        ttl_seconds = 60, max_bytes = 0, platform = PLATFORM,
        now = function() return fake_now end,
        log = function() end,
    }) == false)
check("建目录失败后 enabled=false", dc.enabled() == false)

-- 10b. 相对路径拒绝：不会落到不可预期的 cwd
check("相对路径 → setup=false",
    dc.setup({
        enabled = true,
        dir = "danmaku-cache",
        ttl_seconds = 60, max_bytes = 0, platform = PLATFORM,
        now = function() return fake_now end,
        run_sync = function(cmd) return mp.command_native(cmd) end,
        log = function() end,
    }) == false)
check("相对路径后 enabled=false", dc.enabled() == false)
check("相对路径未在 cwd 建目录", utils.file_info("danmaku-cache") == nil)

-- 11. GC：总量超 max_bytes 按 ts 最旧优先淘汰
setup_opts({ max_bytes = 4500 })
fake_now = fake_now + 1000
dc.put("ep:g1", string.rep("a", 2000), { type = "json", count = 1 })
fake_now = fake_now + 1000
dc.put("ep:g2", string.rep("b", 2000), { type = "json", count = 1 })
fake_now = fake_now + 1000
dc.put("ep:g3", string.rep("c", 2000), { type = "json", count = 1 })
dc.gc()
check("GC 淘汰最旧条目", dc.get_stale("ep:g1") == nil)
check("GC 保留较新条目 g2", dc.get_stale("ep:g2") ~= nil)
check("GC 保留最新条目 g3", dc.get_stale("ep:g3") ~= nil)

-- 12. GC 损坏文件（ts=0）最优先清掉
setup_opts({ max_bytes = 4500 })
fake_now = fake_now + 1000
dc.put("ep:h1", string.rep("d", 2000), { type = "json", count = 1 })
fake_now = fake_now + 1000
dc.put("ep:h2", string.rep("e", 2000), { type = "json", count = 1 })
local junk2 = io.open(TMP .. "/ep_hjunk.dcache", "wb")
junk2:write(string.rep("J", 2000))
junk2:close()
dc.gc()
check("GC 优先清损坏文件", utils.file_info(TMP .. "/ep_hjunk.dcache") == nil)
check("GC 优先清损坏后总量达标（两个完好条目保留）",
    dc.get_stale("ep:h1") ~= nil and dc.get_stale("ep:h2") ~= nil)

-- 13. put 防抖：累计 4 次写入自动触发 GC（未注入 defer → 同步）
setup_opts({ max_bytes = 4096 })
fake_now = fake_now + 1000
dc.put("ep:k1", string.rep("f", 1500), { type = "json", count = 1 })
fake_now = fake_now + 1000
dc.put("ep:k2", string.rep("g", 1500), { type = "json", count = 1 })
fake_now = fake_now + 1000
dc.put("ep:k3", string.rep("h", 1500), { type = "json", count = 1 })
fake_now = fake_now + 1000
dc.put("ep:k4", string.rep("i", 1500), { type = "json", count = 1 })
check("第4次写入自动 GC 淘汰两个最旧",
    dc.get_stale("ep:k1") == nil and dc.get_stale("ep:k2") == nil)
check("自动 GC 保留最新两条",
    dc.get_stale("ep:k3") ~= nil and dc.get_stale("ep:k4") ~= nil)

-- 14. clear：计数、清空、再清为 0（前序 GC 用例可能遗留条目，故只断言下限）
dc.put("ep:c1", "x1", { type = "json", count = 1 })
dc.put("ep:c2", "x2", { type = "json", count = 1 })
check("clear 返回删除条数", dc.clear() >= 2)
check("clear 后 miss", dc.get_stale("ep:c1") == nil and dc.get_stale("ep:c2") == nil)
check("再次 clear 返回 0", dc.clear() == 0)

-- 清理临时目录
dc.clear()
rmdir(TMP)

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
-- os.exit 直杀：mpv 正常 quit 的关机路径在 Windows 控制台代理下偶发挂起（测试环境已知问题）
os.exit(failures > 0 and 1 or 0)
