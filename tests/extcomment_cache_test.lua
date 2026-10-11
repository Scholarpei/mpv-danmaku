-- extcomment 磁盘缓存集成测试：add_danmaku_source_online 的缓存命中不发网络、
-- 未命中走网络且写缓存、损坏条目回网络重写、空结果不写缓存并走兜底、
-- 断网（全服务器无响应）回退过期缓存、断网无缓存照常走兜底
-- （自断言，输出 PASS/FAIL 行）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local utils = require("mp.utils")

local PLATFORM = mp.get_property_native("platform")
    or (os.getenv("windir") ~= nil and "windows" or "linux")

local TMP = (os.getenv("TEMP") or "/tmp")
    .. "/extcomment_cache_test_" .. tostring(os.time()) .. "_"
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

-- ---- 打桩（须在 require 模块前；dandanplay 运行时按全局查找这些名字）----
local stub = { net_calls = 0, loads = 0, fail = false, response = nil, fallbacks = 0 }
show_message = function() end
set_danmaku_button = function() end
load_danmaku = function(from_menu) stub.loads = stub.loads + 1 end
DANMAKU = { sources = {}, count = 1 }
HISTORY_PATH = TMP .. "/history.json"

require("modules/options")
options.api_server = "https://api.example.com"
require("modules/utils")

call_cmd_async = function(args, cb)
    stub.net_calls = stub.net_calls + 1
    mp.add_timeout(0.01, function()
        if stub.fail then
            cb("curl: (7) Failed to connect", nil)
        else
            cb(nil, stub.response)
        end
    end)
    return function() end
end

Sha256 = require("modules/hash")
require("modules/parse")
require("apis/dandanplay")

-- get_danmaku_fallback 打桩（extcomment 全败时的兜底分支计数）
get_danmaku_fallback = function(query)
    stub.fallbacks = stub.fallbacks + 1
end

local dc = require("modules/danmaku_cache")
dc.setup({
    enabled = true, dir = TMP, ttl_seconds = 3600, max_bytes = 0,
    platform = PLATFORM,
    run_sync = function(cmd) return mp.command_native(cmd) end,
    log = function() end,
})

local QQ_URL = "https://v.qq.com/x/cover/c1/v9.html"
local QQ2_URL = "https://v.qq.com/x/cover/c1/v10.html"
local KEY = extcomment_cache_key(QQ_URL)
local KEY2 = extcomment_cache_key(QQ2_URL)

local function payload(comments, count)
    return utils.format_json({ count = count, comments = comments })
end

local TWO = payload({
    { p = "1.00,1,16777215", m = "hi" },
    { p = "2.00,4,9830423", m = "yo" },
}, 2)

local steps = {}

-- ---------- 用例 1：TTL 内命中 → 零网络包，数据入 sources 并加载 ----------
steps[1] = function()
    dc.put(KEY, TWO, { type = "json", count = 2 })
    add_danmaku_source(QQ_URL, false, "腾讯视频")
end

steps[2] = function()
    local src = DANMAKU.sources[QQ_URL]
    check("命中不发包", stub.net_calls == 0)
    check("命中走 load_danmaku", stub.loads == 1)
    check("命中标记 cache", DANMAKU.cache_hit == "cache")
    check("命中数据入 sources", src ~= nil and #src.data == 2)
    check("命中数据字段正确", src and src.data[1].text == "hi"
        and src.data[1].time == 1 and src.data[2].type == 4)
    check("provider 标注保留", src and src.provider == "腾讯视频")
    check("不走兜底", stub.fallbacks == 0)
    DANMAKU.cache_hit = nil
end

-- ---------- 用例 2：未命中 → 走网络一次，成功写缓存 ----------
steps[3] = function()
    stub.net_calls = 0
    stub.fail = false
    stub.response = '{"count":2,"comments":[{"p":"5.00,1,16777215","m":"net1"},'
        .. '{"p":"6.00,4,9830423","m":"net2"}]}'
    add_danmaku_source(QQ2_URL, false)
end

steps[4] = function()
    local src = DANMAKU.sources[QQ2_URL]
    check("未命中发包（并发取数）", stub.net_calls >= 1)
    check("网络数据覆盖 sources", src ~= nil and #src.data == 2 and src.data[1].text == "net1")
    check("网络成功不标 cache", DANMAKU.cache_hit == nil)
    local cached = dc.get(KEY2)
    check("网络成功写缓存", cached ~= nil)
    local roundtrip = cached and utils.parse_json(cached.payload)
    check("缓存载荷可解析且计数正确",
        roundtrip ~= nil and roundtrip.count == 2 and #roundtrip.comments == 2)
    check("不走兜底", stub.fallbacks == 0)
end

-- ---------- 用例 3：损坏缓存条目 → 删除后回网络重写 ----------
steps[5] = function()
    stub.net_calls = 0
    dc.remove(KEY)
    dc.put(KEY, "{broken json!!", { type = "json" })
    add_danmaku_source(QQ_URL, false)
end

steps[6] = function()
    check("损坏条目回网络", stub.net_calls >= 1)
    local cached = dc.get(KEY)
    local roundtrip = cached and utils.parse_json(cached.payload)
    check("损坏条目被网络结果重写",
        roundtrip ~= nil and roundtrip.count == 2)
end

-- ---------- 用例 4：extcomment 无有效数据 → 不写缓存并走兜底 ----------
steps[7] = function()
    stub.net_calls = 0
    stub.response = '{"count":0,"comments":[]}'
    add_danmaku_source("https://v.youku.com/v_show/id_X9.html", false)
end

steps[8] = function()
    check("空结果走兜底服务器", stub.fallbacks == 1)
    check("空结果不写缓存", dc.get(extcomment_cache_key(
        "https://v.youku.com/v_show/id_X9.html")) == nil)
end

-- ---------- 用例 5：缓存键对 URL 稳定（哈希防折叠碰撞的基线） ----------
steps[9] = function()
    local k1 = extcomment_cache_key(QQ_URL)
    local k2 = extcomment_cache_key(QQ_URL)
    check("同 URL 键稳定", k1 == k2 and #k1 > 8)
    check("异 URL 键不同", extcomment_cache_key(QQ_URL)
        ~= extcomment_cache_key("https://v.qq.com/x/cover/c1/v9.html?x=1"))
end

-- ---------- 用例 6：断网（全服务器无响应）→ 过期缓存兜底 ----------
-- 时钟前移 2h 使用例 3 重写的条目过期（get 未命中、get_stale 命中），模拟「断网 + 仅有旧缓存」
steps[10] = function()
    dc.setup({
        enabled = true, dir = TMP, ttl_seconds = 3600, max_bytes = 0,
        platform = PLATFORM,
        run_sync = function(cmd) return mp.command_native(cmd) end,
        now = function() return os.time() + 7200 end,
        log = function() end,
    })
    stub.net_calls = 0
    stub.loads = 0
    stub.fallbacks = 0
    stub.fail = true
    add_danmaku_source(QQ_URL, false)
end

steps[11] = function()
    check("断网有网络尝试", stub.net_calls >= 1)
    check("断网走过期缓存加载", stub.loads == 1)
    check("断网标记 stale", DANMAKU.cache_hit == "stale")
    check("断网不走兜底", stub.fallbacks == 0)
    DANMAKU.cache_hit = nil
end

-- ---------- 用例 7：断网且无过期缓存 → 照常走兜底链 ----------
steps[12] = function()
    stub.net_calls = 0
    add_danmaku_source("https://v.qq.com/x/cover/c1/v11.html", false)
end

steps[13] = function()
    check("断网无缓存走兜底", stub.fallbacks == 1)
    stub.fail = false
end

local function finish()
    dc.clear()
    os.remove(HISTORY_PATH)
    mp.command_native({ name = "subprocess", playback_only = false,
        args = PLATFORM == "windows"
            and { "cmd", "/c", "rmdir", (TMP:gsub("/", "\\")) }
            or { "rmdir", TMP } })
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
    mp.add_timeout(0.15, function()
        s()
        run(i + 1)
    end)
end

run(1)
