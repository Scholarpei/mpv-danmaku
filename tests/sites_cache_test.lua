-- 站点直连加载器磁盘缓存集成测试（animeko / 埋堆堆）：
-- TTL 内命中零网络、未命中走网络且写缓存（原始载荷 roundtrip）、
-- 断网回退过期缓存、合法空结果不写缓存、预取伴生函数同键写/命中跳过
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
    .. "/sites_cache_test_" .. tostring(os.time()) .. "_"
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

-- ---- 打桩（须在 require 模块前；sites 运行时按全局查找这些名字）----
-- save_danmaku_json 用 apis/dandanplay.lua 真身（写 DANMAKU.sources，与在线路径同构）
local stub = { net_calls = 0, fail = false, ako = nil, mdd = nil, loads = 0 }
show_message = function() end
load_danmaku = function(from_menu) stub.loads = stub.loads + 1 end
DANMAKU = { sources = {}, count = 1 }

-- 网络桩：按 URL 分发预置响应（animeko /v1/danmaku/、埋堆堆 vodBarrage396.action）
local AKO_JSON = '{"danmakuList":[{"danmakuInfo":{"text":"hi","playTime":1000,'
    .. '"color":16777215,"location":"NORMAL"}},{"danmakuInfo":{"text":"yo",'
    .. '"playTime":2500,"color":9830415,"location":"TOP"}}]}'
local AKO_EMPTY = '{"danmakuList":[]}'
local MDD_JSON = '{"status":true,"data":[{"barrageList":['
    .. '{"content":"hi","times":"1.5","color":"#FFFFFF"},'
    .. '{"content":"yo","times":"2.5","color":"#00FF00"}]}]}'
local MDD_EMPTY = '{"status":true,"data":[{"barrageList":[]}]}'

require("modules/options")
require("modules/utils")

-- 网络桩须在 require("modules/utils") 之后：utils 加载期定义真身全局 call_cmd_async，
-- 先定义会被覆盖（桩序与 tests/extcomment_cache_test.lua 一致）
call_cmd_async = function(args, cb)
    local url
    for i = #args, 1, -1 do
        local v = args[i]
        if type(v) == "string" and v:find("^https?://") then url = v break end
    end
    stub.net_calls = stub.net_calls + 1
    mp.add_timeout(0.01, function()
        if stub.fail then
            cb("curl: (7) Failed to connect", nil)
            return
        end
        if url:find("/v1/danmaku/") then
            cb(nil, stub.ako)
        elseif url:find("vodBarrage396%.action") then
            cb(nil, stub.mdd)
        else
            cb("unexpected url: " .. tostring(url), nil)
        end
    end)
    return function() end
end

require("modules/parse")
require("apis/dandanplay")
require("sites/animeko")
require("sites/maiduidui")

local dc = require("modules/danmaku_cache")
local function dc_setup(now_fn)
    dc.setup({
        enabled = true, dir = TMP, ttl_seconds = 3600, max_bytes = 0,
        platform = PLATFORM,
        run_sync = function(cmd) return mp.command_native(cmd) end,
        now = now_fn, log = function() end,
    })
end
dc_setup()

local AKO_URL = "https://api.animeko.org/episode/123456"
local MDD_URL = "https://www.mddcloud.com.cn/video/abcdef01.html?uuid=fffeee111"
local AKO_KEY = "ako:123456"
local MDD_KEY = "mdd:fffeee111"

local steps = {}

-- ---------- animeko：命中零网络 ----------
steps[1] = function()
    stub.ako = AKO_JSON
    dc.put(AKO_KEY, AKO_JSON, { type = "json", count = 2 })
    stub.net_calls = 0
    stub.loads = 0
    load_danmaku_for_animeko(AKO_URL, function(success)
        steps._ako_hit_cb = success
    end)
end

steps[2] = function()
    local src = DANMAKU.sources[AKO_URL]
    check("ako 命中零网络", stub.net_calls == 0)
    check("ako 命中回调成功", steps._ako_hit_cb == true)
    check("ako 命中标记 cache", DANMAKU.cache_hit == "cache")
    check("ako 命中走 load_danmaku", stub.loads == 1)
    check("ako 命中数据入 sources", src ~= nil and src.data ~= nil and #src.data == 2)
    check("ako 数据字段正确", src and src.data[1].text == "hi"
        and src.data[1].time == 1 and src.data[1].color == 16777215
        and src.data[2].type == 5 and src.data[2].time == 2.5)
    DANMAKU.cache_hit = nil
end

-- ---------- animeko：未命中走网络并写缓存 ----------
steps[3] = function()
    dc.remove(AKO_KEY)
    stub.net_calls = 0
    load_danmaku_for_animeko(AKO_URL, function() end)
end

steps[4] = function()
    local cached = dc.get(AKO_KEY)
    local roundtrip = cached and utils.parse_json(cached.payload)
    check("ako 未命中发网络", stub.net_calls >= 1)
    check("ako 网络成功不标 cache", DANMAKU.cache_hit == nil)
    check("ako 网络成功写缓存", cached ~= nil)
    check("ako 缓存为原始载荷", roundtrip ~= nil
        and type(roundtrip.danmakuList) == "table" and #roundtrip.danmakuList == 2)
end

-- ---------- animeko：断网回退过期缓存（时钟前移 2h 使条目过期） ----------
steps[5] = function()
    dc_setup(function() return os.time() + 7200 end)
    stub.net_calls = 0
    stub.loads = 0
    stub.fail = true
    load_danmaku_for_animeko(AKO_URL, function(success)
        steps._ako_stale_cb = success
    end)
end

steps[6] = function()
    check("ako 断网全部节点均尝试", stub.net_calls == 4)
    check("ako 断网走过期缓存加载", stub.loads == 1)
    check("ako 断网标记 stale", DANMAKU.cache_hit == "stale")
    check("ako 断网回调成功", steps._ako_stale_cb == true)
    DANMAKU.cache_hit = nil
    stub.fail = false
    dc_setup()
end

-- ---------- animeko：合法空结果不缓存 ----------
steps[7] = function()
    dc.remove(AKO_KEY)
    stub.net_calls = 0
    stub.ako = AKO_EMPTY
    load_danmaku_for_animeko(AKO_URL, function(success)
        steps._ako_empty_cb = success
    end)
end

steps[8] = function()
    check("ako 空结果走网络", stub.net_calls >= 1)
    check("ako 空结果不缓存", dc.get(AKO_KEY) == nil)
    check("ako 空结果回调失败", steps._ako_empty_cb == false)
    stub.ako = AKO_JSON
end

-- ---------- 埋堆堆：命中零网络 ----------
steps[9] = function()
    stub.mdd = MDD_JSON
    dc.put(MDD_KEY, MDD_JSON, { type = "json", count = 2 })
    stub.net_calls = 0
    stub.loads = 0
    load_danmaku_for_maiduidui(MDD_URL, function(success)
        steps._mdd_hit_cb = success
    end)
end

steps[10] = function()
    local src = DANMAKU.sources[MDD_URL]
    check("mdd 命中零网络", stub.net_calls == 0)
    check("mdd 命中回调成功", steps._mdd_hit_cb == true)
    check("mdd 命中标记 cache", DANMAKU.cache_hit == "cache")
    check("mdd 命中走 load_danmaku", stub.loads == 1)
    check("mdd 命中数据入 sources", src ~= nil and src.data ~= nil and #src.data == 2)
    check("mdd 数据字段正确", src and src.data[1].text == "hi"
        and src.data[1].time == 1.5 and src.data[1].color == 16777215
        and src.data[2].color == 65280 and src.data[2].text == "yo")
    DANMAKU.cache_hit = nil
end

-- ---------- 埋堆堆：未命中走网络并写缓存 ----------
steps[11] = function()
    dc.remove(MDD_KEY)
    stub.net_calls = 0
    load_danmaku_for_maiduidui(MDD_URL, function() end)
end

steps[12] = function()
    local cached = dc.get(MDD_KEY)
    local roundtrip = cached and utils.parse_json(cached.payload)
    check("mdd 未命中发网络", stub.net_calls == 1)
    check("mdd 网络成功写缓存", cached ~= nil)
    check("mdd 缓存为原始载荷", roundtrip ~= nil
        and type(roundtrip.data) == "table" and #roundtrip.data == 1)
end

-- ---------- 埋堆堆：断网回退过期缓存 ----------
steps[13] = function()
    dc_setup(function() return os.time() + 7200 end)
    stub.net_calls = 0
    stub.loads = 0
    stub.fail = true
    load_danmaku_for_maiduidui(MDD_URL, function(success)
        steps._mdd_stale_cb = success
    end)
end

steps[14] = function()
    check("mdd 断网单次请求", stub.net_calls == 1)
    check("mdd 断网走过期缓存加载", stub.loads == 1)
    check("mdd 断网标记 stale", DANMAKU.cache_hit == "stale")
    check("mdd 断网回调成功", steps._mdd_stale_cb == true)
    DANMAKU.cache_hit = nil
    stub.fail = false
    dc_setup()
end

-- ---------- 埋堆堆：合法空结果不缓存 ----------
steps[15] = function()
    dc.remove(MDD_KEY)
    stub.net_calls = 0
    stub.mdd = MDD_EMPTY
    load_danmaku_for_maiduidui(MDD_URL, function(success)
        steps._mdd_empty_cb = success
    end)
end

steps[16] = function()
    check("mdd 空结果走网络", stub.net_calls == 1)
    check("mdd 空结果不缓存", dc.get(MDD_KEY) == nil)
    check("mdd 空结果回调失败", steps._mdd_empty_cb == false)
    stub.mdd = MDD_JSON
end

-- ---------- 预取伴生函数：走网络写同键 / TTL 命中零网络 ----------
steps[17] = function()
    stub.net_calls = 0
    prefetch_animeko_danmaku("123456", function(done)
        steps._ako_pf_net = done
    end)
    prefetch_maiduidui_danmaku("abcdef01", "fffeee111", function(done)
        steps._mdd_pf_net = done
    end)
end

steps[18] = function()
    check("ako 预取走网络写同键缓存",
        steps._ako_pf_net == true and dc.get(AKO_KEY) ~= nil)
    check("mdd 预取走网络写同键缓存",
        steps._mdd_pf_net == true and dc.get(MDD_KEY) ~= nil)
    stub.net_calls = 0
    prefetch_animeko_danmaku("123456", function(done)
        steps._ako_pf_hit = done
    end)
    prefetch_maiduidui_danmaku("abcdef01", "fffeee111", function(done)
        steps._mdd_pf_hit = done
    end)
end

steps[19] = function()
    check("ako 预取 TTL 命中零网络", steps._ako_pf_hit == true and stub.net_calls == 0)
    check("mdd 预取 TTL 命中零网络", steps._mdd_pf_hit == true and stub.net_calls == 0)
end

local function finish()
    dc.clear()
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
