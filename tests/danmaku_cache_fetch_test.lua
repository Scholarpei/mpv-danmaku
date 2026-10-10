-- danmaku_cache 集成测试：fetch_danmaku 的缓存命中不发网络（自断言，输出 PASS/FAIL 行）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败
-- 覆盖：TTL 命中零网络包 / 未命中走网络且写缓存 / 断网过期缓存兜底 / count==0 不缓存

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local utils = require("mp.utils")

local PLATFORM = mp.get_property_native("platform")
    or (os.getenv("windir") ~= nil and "windows" or "linux")

local TMP = (os.getenv("TEMP") or "/tmp")
    .. "/danmaku_cache_fetch_test_" .. tostring(os.time()) .. "_"
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

-- ---- 打桩（须在 require 模块前；dandanplay 运行时按全局查找这些名字）----
local stub = { net_calls = 0, loads = 0, fail = false, response = nil }
show_message = function() end
load_danmaku = function(from_menu) stub.loads = stub.loads + 1 end
DANMAKU = { sources = {}, count = 1 }

require("modules/options")
options.fallback_server = ""
require("modules/utils")

-- 覆盖全局 call_cmd_async：计数网络调用，模拟异步返回（错误或预置响应）
call_cmd_async = function(args, cb)
    stub.net_calls = stub.net_calls + 1
    mp.add_timeout(0.01, function()
        if stub.fail then
            cb("curl: (7) Failed to connect", nil)
        else
            cb(nil, stub.response)
        end
    end)
end

require("modules/parse")
require("apis/dandanplay")

local dc = require("modules/danmaku_cache")
local fake_now = os.time()
local TTL = 3600
dc.setup({
    enabled = true, dir = TMP, ttl_seconds = TTL, max_bytes = 0,
    platform = PLATFORM,
    now = function() return fake_now end,
    run_sync = function(cmd) return mp.command_native(cmd) end,
    log = function() end,
})

local function comment_url(episodeId)
    return "https://api.example.com/api/v2/comment/" .. episodeId
        .. "?withRelated=true&chConvert=0"
end

local function payload(comments, count)
    return utils.format_json({ count = count, comments = comments })
end

local TWO = payload({
    { p = "1.00,1,16777215", m = "hi" },
    { p = "2.00,4,9830423", m = "yo" },
}, 2)

-- ---------- 用例 1：TTL 内命中 → 零网络包，同步完成 ----------
dc.put("ep:1001", TWO, { type = "json", count = 2 })
fetch_danmaku(1001, false, "https://api.example.com")
local src1 = DANMAKU.sources[comment_url(1001)]
check("命中不发包", stub.net_calls == 0)
check("命中走 load_danmaku", stub.loads == 1)
check("命中标记 cache", DANMAKU.cache_hit == "cache")
check("命中数据入 sources", src1 ~= nil and #src1.data == 2)
check("命中数据字段正确", src1 and src1.data[1].text == "hi"
    and src1.data[1].time == 1 and src1.data[1].color == 16777215
    and src1.data[2].type == 4)

-- ---------- 用例 2：未命中 → 走网络一次，成功且非空写缓存 ----------
local steps = {}

steps[1] = function()
    stub.net_calls, stub.fail = 0, false
    stub.response = '{"count":2,"comments":[{"cid":11,"p":"5.00,1,16777215","m":"net1"},'
        .. '{"cid":12,"p":"6.00,4,9830423","m":"net2"}]}'
    DANMAKU.cache_hit = nil
    fetch_danmaku(1002, false, "https://api.example.com")
end

steps[2] = function()
    local src = DANMAKU.sources[comment_url(1002)]
    check("未命中发包一次", stub.net_calls == 1)
    check("网络数据入 sources", src ~= nil and #src.data == 2 and src.data[1].text == "net1")
    check("网络成功不标 cache", DANMAKU.cache_hit == nil)
    local cached = dc.get("ep:1002")
    check("网络成功写缓存", cached ~= nil)
    local roundtrip = cached and utils.parse_json(cached.payload)
    check("缓存载荷可解析且计数正确",
        roundtrip ~= nil and roundtrip.count == 2 and #roundtrip.comments == 2)
end

-- ---------- 用例 3：断网 + 过期缓存 → stale 兜底 ----------
steps[3] = function()
    stub.net_calls, stub.fail = 0, true
    dc.put("ep:1003", TWO, { type = "json", count = 2 })
    fake_now = fake_now + TTL + 100   -- 推进假时钟使条目过期
    DANMAKU.cache_hit = nil
    fetch_danmaku(1003, false, "https://api.example.com")
end

steps[4] = function()
    local src = DANMAKU.sources[comment_url(1003)]
    check("断网时仍发包一次（尝试失败）", stub.net_calls == 1)
    check("stale 标记", DANMAKU.cache_hit == "stale")
    check("stale 数据入 sources 并加载", src ~= nil and #src.data == 2 and stub.loads == 3)
end

-- ---------- 用例 4：count==0 → 不写缓存 ----------
steps[5] = function()
    stub.net_calls, stub.fail = 0, false
    stub.response = '{"count":0,"comments":[]}'
    fetch_danmaku(1004, false, "https://api.example.com")
end

steps[6] = function()
    check("count==0 不写缓存", dc.get("ep:1004") == nil and dc.get_stale("ep:1004") == nil)
end

local function rmdir(path)
    if PLATFORM == "windows" then
        mp.command_native({ name = "subprocess", playback_only = false,
            args = { "cmd", "/c", "rmdir", (path:gsub("/", "\\")) } })
    else
        mp.command_native({ name = "subprocess", playback_only = false,
            args = { "rmdir", path } })
    end
end

local function finish()
    dc.clear()
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
    mp.add_timeout(0.1, function()
        s()
        run(i + 1)
    end)
end

run(1)
