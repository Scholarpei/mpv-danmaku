-- 站点直连加载器磁盘缓存集成测试（animeko / 埋堆堆 / 巴哈姆特 / AcFun）：
-- TTL 内命中零网络、未命中走网络且写缓存（原始载荷 roundtrip）、
-- 断网回退过期缓存、合法空结果不写缓存、巴哈主/降级端口取数均写同键缓存、
-- AcFun 两级缓存（映射 acfmap + 弹幕 acf）与分页游标聚合、预取伴生函数同键写/命中跳过
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
local stub = { net_calls = 0, fail = false, ako = nil, mdd = nil, loads = 0,
    baha = nil, baha_api = nil, baha_fail_main = false,
    acf_page = nil, acf_p0 = nil, acf_p1 = nil }
show_message = function() end
load_danmaku = function(from_menu) stub.loads = stub.loads + 1 end
DANMAKU = { sources = {}, count = 1 }
-- 巴哈加载器的临时文件落点（main.lua 运行期同款全局）
DANMAKU_PATH = TMP
PID = 770001

-- 网络桩：按 URL 分发预置响应（animeko /v1/danmaku/、埋堆堆 vodBarrage396.action、
-- 巴哈 ani.gamer.com.tw/ajax/danmuGet.php 与 api.gamer.com.tw/anime/v1/danmu.php）
local AKO_JSON = '{"danmakuList":[{"danmakuInfo":{"text":"hi","playTime":1000,'
    .. '"color":16777215,"location":"NORMAL"}},{"danmakuInfo":{"text":"yo",'
    .. '"playTime":2500,"color":9830415,"location":"TOP"}}]}'
local AKO_EMPTY = '{"danmakuList":[]}'
local MDD_JSON = '{"status":true,"data":[{"barrageList":['
    .. '{"content":"hi","times":"1.5","color":"#FFFFFF"},'
    .. '{"content":"yo","times":"2.5","color":"#00FF00"}]}]}'
local MDD_EMPTY = '{"status":true,"data":[{"barrageList":[]}]}'
-- 巴哈两端口条目字段同构（color/position/time/text）
local BAHA_JSON = '[{"color":"#FFFFFF","position":0,"time":1500,"text":"hi"},'
    .. '{"color":"#00FF00","position":1,"time":2500,"text":"yo"}]'
local BAHA_API_JSON = '{"data":{"danmu":' .. BAHA_JSON .. '}}'
local BAHA_EMPTY = "[]"
local BAHA_API_EMPTY = '{"data":{"danmu":[]},"count":0}'
-- AcFun：视频页内嵌 pageInfo（单P）；弹幕两页（pcursor "2" → no_more）
local ACF_PAGE_HTML = '<html><script>window.pageInfo = ' .. utils.format_json({
    title = "测试视频",
    videoList = { { id = 30010597, title = "测试视频 P1" } },
}) .. ';</script></html>'
local ACF_P0 = '{"result":0,"totalCount":3,"pcursor":"2","danmakus":['
    .. '{"body":"hi","position":1500,"color":16777215,"mode":1},'
    .. '{"body":"yo","position":2500,"color":9830415,"mode":5}]}'
local ACF_P1 = '{"result":0,"totalCount":3,"pcursor":"no_more","danmakus":['
    .. '{"body":"底","position":3000,"color":16711680,"mode":4}]}'
local ACF_EMPTY = '{"result":0,"totalCount":0,"pcursor":"no_more","danmakus":[]}'

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
        elseif url:find("ani%.gamer%.com%.tw/ajax/danmuGet%.php") then
            -- 巴哈主端口：真实 curl 经 --output 把响应落盘临时文件，桩模拟该副作用
            if stub.baha_fail_main then
                cb("curl: (7) Failed to connect", nil)
                return
            end
            local out_path
            for i, v in ipairs(args) do
                if v == "--output" then out_path = args[i + 1] break end
            end
            if out_path and stub.baha then
                local f = io.open(out_path, "wb")
                if f then f:write(stub.baha) f:close() end
            end
            cb(nil, "")
        elseif url:find("api%.gamer%.com%.tw/anime/v1/danmu%.php") then
            cb(nil, stub.baha_api)
        elseif url:find("acfun%.cn/v/ac") then
            cb(nil, stub.acf_page)
        elseif url:find("new%-danmaku/list") then
            -- 弹幕分页：按表单 pcursor 分发（真实 curl 经 -d 携带表单）
            local form
            for i, v in ipairs(args) do
                if v == "-d" then form = args[i + 1] break end
            end
            local cur = form and form:match("pcursor=(%d+)") or "0"
            cb(nil, cur == "0" and stub.acf_p0 or stub.acf_p1)
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
require("sites/bahamut")
require("sites/acfun")

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
local BAHA_URL = "https://ani.gamer.com.tw/animeVideo.php?sn=12345"
local AKO_KEY = "ako:123456"
local MDD_KEY = "mdd:fffeee111"
local BAHA_KEY = "baha:12345"

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

-- ---------- 巴哈姆特：命中零网络 ----------
steps[20] = function()
    stub.baha = BAHA_JSON
    stub.baha_api = BAHA_API_JSON
    dc.put(BAHA_KEY, BAHA_JSON, { type = "json", count = 2 })
    stub.net_calls = 0
    stub.loads = 0
    load_danmaku_for_bahamut(BAHA_URL, function(success)
        steps._baha_hit_cb = success
    end)
end

steps[21] = function()
    local src = DANMAKU.sources[BAHA_URL]
    check("baha 命中零网络", stub.net_calls == 0)
    check("baha 命中回调成功", steps._baha_hit_cb == true)
    check("baha 命中标记 cache", DANMAKU.cache_hit == "cache")
    check("baha 命中走 load_danmaku", stub.loads == 1)
    check("baha 命中数据入 sources", src ~= nil and src.data ~= nil and #src.data == 2)
    check("baha 数据字段正确（time/10、hex 色、position→mode）", src and src.data[1].text == "hi"
        and src.data[1].time == 150 and src.data[1].color == 16777215
        and src.data[1].type == 1
        and src.data[2].type == 4 and src.data[2].color == 65280)
    DANMAKU.cache_hit = nil
end

-- ---------- 巴哈姆特：未命中走主端口网络并写缓存 ----------
steps[22] = function()
    dc.remove(BAHA_KEY)
    stub.net_calls = 0
    load_danmaku_for_bahamut(BAHA_URL, function() end)
end

steps[23] = function()
    local cached = dc.get(BAHA_KEY)
    local roundtrip = cached and utils.parse_json(cached.payload)
    check("baha 未命中发网络", stub.net_calls == 1)
    check("baha 网络成功不标 cache", DANMAKU.cache_hit == nil)
    check("baha 网络成功写缓存", cached ~= nil)
    check("baha 缓存为 comments 数组载荷", roundtrip ~= nil
        and type(roundtrip[1]) == "table" and roundtrip[1].text == "hi"
        and roundtrip[2].position == 1)
end

-- ---------- 巴哈姆特：断网回退过期缓存（时钟前移 2h 使条目过期） ----------
steps[24] = function()
    dc_setup(function() return os.time() + 7200 end)
    stub.net_calls = 0
    stub.loads = 0
    stub.fail = true
    load_danmaku_for_bahamut(BAHA_URL, function(success)
        steps._baha_stale_cb = success
    end)
end

steps[25] = function()
    check("baha 断网两端口均尝试", stub.net_calls == 2)
    check("baha 断网走过期缓存加载", stub.loads == 1)
    check("baha 断网标记 stale", DANMAKU.cache_hit == "stale")
    check("baha 断网回调成功", steps._baha_stale_cb == true)
    DANMAKU.cache_hit = nil
    stub.fail = false
    dc_setup()
end

-- ---------- 巴哈姆特：主端口失败降级端口取数同写缓存 ----------
steps[26] = function()
    dc.remove(BAHA_KEY)
    stub.net_calls = 0
    stub.baha_fail_main = true
    load_danmaku_for_bahamut(BAHA_URL, function(success)
        steps._baha_fallback_cb = success
    end)
end

steps[27] = function()
    check("baha 降级端口两跳请求", stub.net_calls == 2)
    check("baha 降级端口回调成功", steps._baha_fallback_cb == true)
    check("baha 降级端口写同键缓存", dc.get(BAHA_KEY) ~= nil)
    check("baha 降级端口不标 cache", DANMAKU.cache_hit == nil)
    stub.baha_fail_main = false
end

-- ---------- 巴哈姆特：合法空结果不缓存 ----------
steps[28] = function()
    dc.remove(BAHA_KEY)
    stub.net_calls = 0
    stub.baha = BAHA_EMPTY
    stub.baha_api = BAHA_API_EMPTY
    load_danmaku_for_bahamut(BAHA_URL, function(success)
        steps._baha_empty_cb = success
    end)
end

steps[29] = function()
    check("baha 空结果两端口均尝试", stub.net_calls == 2)
    check("baha 空结果不缓存", dc.get(BAHA_KEY) == nil)
    check("baha 空结果回调失败", steps._baha_empty_cb == false)
    stub.baha = BAHA_JSON
    stub.baha_api = BAHA_API_JSON
end

-- ---------- AcFun：两级缓存均命中零网络（映射 acfmap + 弹幕 acf） ----------
local ACF_URL = "https://www.acfun.cn/v/ac40407984?part=1"
local ACF_MAP_KEY = "acfmap:40407984:1"
local ACF_KEY = "acf:30010597"

steps[30] = function()
    stub.acf_page = ACF_PAGE_HTML
    stub.acf_p0 = ACF_P0
    stub.acf_p1 = ACF_P1
    -- 聚合载荷（与 loader 成功路径写入的形状同构）
    dc.put(ACF_MAP_KEY, utils.format_json({ video_id = "30010597", title = "测试视频 P1" }), { type = "json" })
    dc.put(ACF_KEY, '{"result":0,"totalCount":3,"pcursor":"no_more","danmakus":['
        .. '{"body":"hi","position":1500,"color":16777215,"mode":1},'
        .. '{"body":"yo","position":2500,"color":9830415,"mode":5},'
        .. '{"body":"底","position":3000,"color":16711680,"mode":4}]}',
        { type = "json", count = 3 })
    stub.net_calls = 0
    stub.loads = 0
    load_danmaku_for_acfun(ACF_URL, function(success)
        steps._acf_hit_cb = success
    end)
end

steps[31] = function()
    local src = DANMAKU.sources[ACF_URL]
    check("acf 命中零网络", stub.net_calls == 0)
    check("acf 命中回调成功", steps._acf_hit_cb == true)
    check("acf 命中标记 cache", DANMAKU.cache_hit == "cache")
    check("acf 命中走 load_danmaku", stub.loads == 1)
    check("acf 命中数据入 sources", src ~= nil and src.data ~= nil and #src.data == 3)
    check("acf 数据字段正确（position ms→s、mode 透传）", src and src.data[1].text == "hi"
        and src.data[1].time == 1.5 and src.data[1].color == 16777215 and src.data[1].type == 1
        and src.data[2].type == 5 and src.data[3].type == 4 and src.data[3].color == 16711680)
    DANMAKU.cache_hit = nil
end

-- ---------- AcFun：弹幕未命中走分页网络并聚合写缓存 ----------
steps[32] = function()
    dc.remove(ACF_KEY)
    stub.net_calls = 0
    load_danmaku_for_acfun(ACF_URL, function() end)
end

steps[33] = function()
    local cached = dc.get(ACF_KEY)
    local roundtrip = cached and utils.parse_json(cached.payload)
    local src = DANMAKU.sources[ACF_URL]
    check("acf 分页两跳请求（pcursor 0→2）", stub.net_calls == 2)
    check("acf 网络成功不标 cache", DANMAKU.cache_hit == nil)
    check("acf 聚合写缓存", cached ~= nil and cached.meta ~= nil and cached.meta.count == 3)
    check("acf 缓存为聚合载荷", roundtrip ~= nil and type(roundtrip.danmakus) == "table"
        and #roundtrip.danmakus == 3 and roundtrip.pcursor == "no_more")
    check("acf 聚合数据入 sources", src ~= nil and src.data ~= nil and #src.data == 3
        and src.data[3].text == "底" and src.data[3].time == 3)
end

-- ---------- AcFun：断网回退过期缓存（映射与弹幕均过期，页面请求失败走映射过期兜底） ----------
steps[34] = function()
    dc_setup(function() return os.time() + 7200 end)
    stub.net_calls = 0
    stub.loads = 0
    stub.fail = true
    load_danmaku_for_acfun(ACF_URL, function(success)
        steps._acf_stale_cb = success
    end)
end

steps[35] = function()
    check("acf 断网两跳请求失败（页面 + 弹幕首页，随后双双过期兜底）", stub.net_calls == 2)
    check("acf 断网走过期缓存加载", stub.loads == 1)
    check("acf 断网标记 stale", DANMAKU.cache_hit == "stale")
    check("acf 断网回调成功", steps._acf_stale_cb == true)
    DANMAKU.cache_hit = nil
    stub.fail = false
    dc_setup()
end

-- ---------- AcFun：合法空结果不缓存 ----------
steps[36] = function()
    dc.remove(ACF_KEY)
    stub.net_calls = 0
    stub.acf_p0 = ACF_EMPTY
    load_danmaku_for_acfun(ACF_URL, function(success)
        steps._acf_empty_cb = success
    end)
end

steps[37] = function()
    check("acf 空结果走网络", stub.net_calls >= 1)
    check("acf 空结果不缓存", dc.get(ACF_KEY) == nil)
    check("acf 空结果回调失败", steps._acf_empty_cb == false)
    stub.acf_p0 = ACF_P0
end

-- ---------- AcFun：预取伴生函数走网络写同键 / TTL 命中零网络 ----------
steps[38] = function()
    dc.remove(ACF_KEY)
    stub.net_calls = 0
    prefetch_acfun_danmaku("40407984", 1, function(done)
        steps._acf_pf_net = done
    end)
end

steps[39] = function()
    check("acf 预取走网络写同键缓存",
        steps._acf_pf_net == true and dc.get(ACF_KEY) ~= nil)
    stub.net_calls = 0
    prefetch_acfun_danmaku("40407984", 1, function(done)
        steps._acf_pf_hit = done
    end)
end

steps[40] = function()
    check("acf 预取 TTL 命中零网络", steps._acf_pf_hit == true and stub.net_calls == 0)
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
