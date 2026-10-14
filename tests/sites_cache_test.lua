-- 站点直连加载器磁盘缓存集成测试（animeko / 埋堆堆 / 巴哈姆特 / AcFun / ezdmw / girigirilove /
-- 爱壹帆 / 次元城 / OmoFun）：
-- TTL 内命中零网络、未命中走网络且写缓存（原始载荷 roundtrip）、
-- 断网回退过期缓存、合法空结果不写缓存、巴哈主/降级端口取数均写同键缓存、
-- AcFun 两级缓存（映射 acfmap + 弹幕 acf）与分页游标聚合、
-- ezdmw 单级缓存（播放页取 nk+sign → getData XML）与双域降级、预取伴生函数同键写/命中跳过、
--   播放页无弹幕播放器（第三方解析源）按确定性无弹幕处理（no_data 判定、不走过期缓存）、
-- girigirilove 单级缓存（播放页 player_aaaa 解裸 m3u8 → POST getScrolling）与
-- 备用域 URL 同键命中、接口错误（code≠1）与合法空（code=1 空表）两口径区分、
-- 爱壹帆单级缓存（home/config 密钥引导 → 签名 GetBarrages）与签名头校验、
-- 老链接缺 videoId 经 VideoDetails 补齐、接口错误（ret≠200）强刷密钥重试一次、
-- 网络失败不重试直接过期兜底、
-- 次元城单级缓存（分集表定位 section_id → GET danmaku）与 x-app-name 头校验、
-- 分集表会话缓存（同番换集单跳）、长番串行翻页（page_size=100 取满 pager.total）、
-- 集数越界确定性无弹幕（no_data 判定）、粘贴网页 URL（带 ?from=）同键命中
-- （自断言，输出 PASS/FAIL 行）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local utils = require("mp.utils")
local b64 = require("modules/base64")
local md5 = require("modules/md5")

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
    acf_page = nil, acf_p0 = nil, acf_p1 = nil,
    ezd_page = nil, ezd_data = nil, ezd_fail_main = false,
    ggl_page = nil, ggl_data = nil, ggl_body = nil,
    ayf_config = nil, ayf_data = nil, ayf_details = nil, ayf_calls = {},
    cyc_sections = nil, cyc_data = nil, cyc_calls = {},
    omf_doh = nil, omf_detail = nil, omf_data = nil, omf_calls = {} }
local msgs = {}
show_message = function(text) msgs[#msgs + 1] = tostring(text) end
load_danmaku = function(from_menu) stub.loads = stub.loads + 1 end
DANMAKU = { sources = {}, count = 1 }
-- 巴哈加载器的临时文件落点（main.lua 运行期同款全局）
DANMAKU_PATH = TMP
PID = 770001
-- 统计台账真模块（main.lua 以全局注入；sites 加载器的 note_cache/失败原因透传消费，
-- 模块自身无 mp.* 依赖，配合上面的 show_message/DANMAKU 桩即可工作）
source_status = require("modules/source_status")

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
-- ezdmw：播放页内嵌弹幕播放器 iframe（nk+sign）；getData 为 B站标准 XML（mode 1/5/4 + 实体）
local EZD_PAGE_HTML = '<html><iframe src="https://player.ezdmw.com/danmuku/'
    .. '?nk=testres/testres_01&name=x&sign=abc123abc123abc123abc123abc123ab"></iframe></html>'
local EZD_XML = '<?xml version="1.0" encoding="utf-8"?><i>'
    .. '<d p="1.5,1,22,16777215,0,0,u,1">hi</d>'
    .. '<d p="2.5,5,25,9830415,0,0,u,2">顶</d>'
    .. '<d p="3.5,4,25,16711680,0,0,u,3">底</d>'
    .. '<d p="4.5,1,25,16777215,0,0,u,4">a&lt;b&gt;c&amp;d</d></i>'
local EZD_EMPTY = '<?xml version="1.0" encoding="utf-8"?><i></i>'
-- 第三方解析源播放页（实抓 ezd_player_noplayer.html 同构）：仅 jx 解析 iframe + 评论区
-- iframe、无 E站弹幕播放器（nk/sign 无处可取）
local EZD_NOPLAYER_HTML = '<html><iframe class="iframe" '
    .. 'src="//jx.aidouer.net/?url=http://v.pptv.com/show/s6Fk4tSKgsAjoQk.html"></iframe>'
    .. '<iframe style="width:100%;height:600px;" id="IFeditValue" '
    .. 'src="/comment/?comment_index=nk=32869"></iframe></html>'
-- girigirilove：播放页内嵌 player_aaaa（encrypt=2，站方为逐字符 %XX 全编码后 base64——
-- 测试运行时自建编码链避免手抄常量；弹幕 getScrolling 为 JSON，mode 1/2/3=滚动/顶/底 →
-- B站 1/5/4，色在 style.color 含 8 位变体）
local GGL_M3U8 = "https://test.girigirilove.com/anime/2026/01/cht/StubCHT/01/playlist.m3u8"
local GGL_PCT = GGL_M3U8:gsub(".", function(c) return string.format("%%%02X", c:byte()) end)
local GGL_PAGE_HTML = '<html><script>var player_aaaa={"flag":"play","encrypt":2,'
    .. '"url":"' .. b64.encode(GGL_PCT) .. '","from":"cht","id":"26868","sid":1,"nid":1};'
    .. '</script></html>'
local GGL_JSON = '{"code":1,"msg":"success","info":['
    .. '{"scroll_id":1,"scroll_json":{"stime":0,"mode":1,"text":"","color":"","time":1.5,'
    .. '"content":"hi","style":{"color":"#ffffff","border":"x"},"duration":8}},'
    .. '{"scroll_id":2,"scroll_json":{"stime":0,"mode":2,"text":"","color":"","time":2.5,'
    .. '"content":"顶","style":{"color":"#ffffffff","border":"x"},"duration":4}},'
    .. '{"scroll_id":3,"scroll_json":{"stime":0,"mode":3,"text":"","color":"","time":3.5,'
    .. '"content":"底","style":{"color":"#ff33ff","border":"x"},"duration":4}}]}'
local GGL_EMPTY = '{"code":1,"msg":"success","info":[]}'
local GGL_ERR = '{"code":0,"msg":"error"}'
-- 爱壹帆：home/config 密钥引导（pConfig 密钥对）→ 签名 GetBarrages JSON（position
-- 0滚动/1顶/2底，文本 contxt 优先 content 备选）；VideoDetails 为老链接补 uniqueID
local AYF_CONFIG = '{"ret":200,"data":{"list":{"pConfig":{"publicKey":"testpub123",'
    .. '"privateKey":["testpriv456"]}}}}'
local AYF_JSON = '{"ret":200,"data":{"list":['
    .. '{"second":1.5,"position":0,"color":"#ffffff","contxt":"hi","good":0},'
    .. '{"second":2.5,"position":1,"color":"#00FF00","contxt":"顶","good":1},'
    .. '{"second":3.5,"position":2,"color":"#ff0000","content":"底（content备选）","good":0}]}}'
local AYF_EMPTY = '{"ret":200,"data":{"list":[]},"msg":"ok"}'
local AYF_ERR = '{"ret":401,"msg":"sign error"}'
local AYF_DETAILS = '{"ret":200,"data":{"detailInfo":{"uniqueID":999888,'
    .. '"episodeId":999999,"videoType":1}}}'

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
    -- 爱壹帆签名链请求全量捕获（URL + 完整 curl args，供签名头断言）
    if url and url:find("api%.tripdata%.app") then
        stub.ayf_calls[#stub.ayf_calls + 1] = { url = url, args = args }
    end
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
        elseif url:find("ezdmw%.org/Index/video/") then
            cb(nil, stub.ezd_page)
        elseif url:find("player%.ezdmw%.com/index/getData") then
            if stub.ezd_fail_main then
                cb("curl: (7) Failed to connect", nil)
                return
            end
            cb(nil, stub.ezd_data)
        elseif url:find("player%.danmuzf%.vip/index/getData") then
            cb(nil, stub.ezd_data)
        elseif url:find("girigirilove%.com/playGV") then
            cb(nil, stub.ggl_page)
        elseif url:find("m3u8%.girigirilove%.com/api%.php/Scrolling/getScrolling") then
            -- 弹幕 POST：真实 curl 经 -d 携带 JSON body（捕获供断言解码后的裸 m3u8）
            for i, v in ipairs(args) do
                if v == "-d" then stub.ggl_body = args[i + 1] break end
            end
            cb(nil, stub.ggl_data)
        elseif url:find("api%.tripdata%.app/api/home/config") then
            cb(nil, stub.ayf_config)
        elseif url:find("api%.tripdata%.app/api/Video/VideoDetails") then
            cb(nil, stub.ayf_details)
        elseif url:find("api%.tripdata%.app/api/Video/GetBarrages") then
            cb(nil, stub.ayf_data)
        elseif url:find("cycani%.org/api/videos/.-/sections") then
            -- 次元城分集表：捕获完整 curl args（供 x-app-name 头断言）；按 (vid, page)
            -- 分发预置页（长番翻页场景 vid=780 多页）
            stub.cyc_calls[#stub.cyc_calls + 1] = { url = url, args = args }
            local page = tonumber(url:match("page=(%d+)")) or 1
            if stub.cyc_sections_pages then
                local vid = url:match("/api/videos/(%d+)/sections")
                cb(nil, stub.cyc_sections_pages[vid] and stub.cyc_sections_pages[vid][page])
            else
                cb(nil, stub.cyc_sections)
            end
        elseif url:find("cycani%.org/api/sections/") then
            stub.cyc_calls[#stub.cyc_calls + 1] = { url = url, args = args }
            cb(nil, stub.cyc_data)
        elseif url:find("doh%.pub/resolve") or url:find("223%.5%.5%.5/resolve")
            or url:find("1%.12%.12%.12/resolve") then
            -- OmoFun 域名发现 DoH：nil = 解析器不可达（串行下一家/全失败走内置兜底 base）
            stub.omf_calls[#stub.omf_calls + 1] = { url = url, args = args }
            if stub.omf_doh then
                cb(nil, stub.omf_doh)
            else
                cb("curl: (7) Failed to connect", nil)
            end
        elseif url:find("/app/v2/vod/") then
            stub.omf_calls[#stub.omf_calls + 1] = { url = url, args = args }
            cb(nil, stub.omf_detail)
        elseif url:find("app/chat/barragev2") then
            stub.omf_calls[#stub.omf_calls + 1] = { url = url, args = args }
            cb(nil, stub.omf_data)
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
require("sites/ezdmw")
require("sites/ggl")
require("sites/aiyifan")
require("sites/cyc")
require("sites/omofun")

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

-- ---------- ezdmw：TTL 命中零网络（单级缓存 ezd:{videoId}，存原始 XML） ----------
local EZD_URL = "https://www.ezdmw.org/Index/video/102578.html"
local EZD_KEY = "ezd:102578"

steps[41] = function()
    stub.ezd_page = EZD_PAGE_HTML
    stub.ezd_data = EZD_XML
    dc.put(EZD_KEY, EZD_XML, { type = "xml", count = 4 })
    stub.net_calls = 0
    stub.loads = 0
    load_danmaku_for_ezdmw(EZD_URL, function(success)
        steps._ezd_hit_cb = success
    end)
end

steps[42] = function()
    local src = DANMAKU.sources[EZD_URL]
    check("ezd 命中零网络", stub.net_calls == 0)
    check("ezd 命中回调成功", steps._ezd_hit_cb == true)
    check("ezd 命中标记 cache", DANMAKU.cache_hit == "cache")
    check("ezd 命中走 load_danmaku", stub.loads == 1)
    check("ezd 命中数据入 sources", src ~= nil and src.data ~= nil and #src.data == 4)
    check("ezd 数据字段正确（mode 透传、实体反转义）", src and src.data[1].text == "hi"
        and src.data[1].time == 1.5 and src.data[1].color == 16777215 and src.data[1].type == 1
        and src.data[2].type == 5 and src.data[3].type == 4 and src.data[3].color == 16711680
        and src.data[4].text == "a<b>c&d")
    DANMAKU.cache_hit = nil
end

-- ---------- ezdmw：未命中走网络（播放页取 nk+sign → getData）且聚合写缓存 ----------
steps[43] = function()
    dc.remove(EZD_KEY)
    stub.net_calls = 0
    load_danmaku_for_ezdmw(EZD_URL, function() end)
end

steps[44] = function()
    local cached = dc.get(EZD_KEY)
    local src = DANMAKU.sources[EZD_URL]
    check("ezd 网络两跳请求（播放页 + getData）", stub.net_calls == 2)
    check("ezd 网络成功不标 cache", DANMAKU.cache_hit == nil)
    check("ezd 原始 XML 写缓存 roundtrip", cached ~= nil and cached.payload == EZD_XML)
    check("ezd 缓存 meta 计数", cached ~= nil and cached.meta ~= nil and cached.meta.count == 4)
    check("ezd 网络数据入 sources", src ~= nil and src.data ~= nil and #src.data == 4
        and src.data[4].text == "a<b>c&d")
end

-- ---------- ezdmw：断网回退过期缓存（播放页请求失败即走过期兜底） ----------
steps[45] = function()
    dc_setup(function() return os.time() + 7200 end)
    stub.net_calls = 0
    stub.loads = 0
    stub.fail = true
    load_danmaku_for_ezdmw(EZD_URL, function(success)
        steps._ezd_stale_cb = success
    end)
end

steps[46] = function()
    check("ezd 断网播放页请求失败（不再取弹幕）", stub.net_calls == 1)
    check("ezd 断网走过期缓存加载", stub.loads == 1)
    check("ezd 断网标记 stale", DANMAKU.cache_hit == "stale")
    check("ezd 断网回调成功", steps._ezd_stale_cb == true)
    DANMAKU.cache_hit = nil
    stub.fail = false
    dc_setup()
end

-- ---------- ezdmw：主域 getData 失败降级备用域（同写同键） ----------
steps[47] = function()
    dc.remove(EZD_KEY)
    stub.net_calls = 0
    stub.ezd_fail_main = true
    load_danmaku_for_ezdmw(EZD_URL, function(success)
        steps._ezd_backup_cb = success
    end)
end

steps[48] = function()
    local src = DANMAKU.sources[EZD_URL]
    check("ezd 主域失败三跳请求（播放页 + 主域 + 备用域）", stub.net_calls == 3)
    check("ezd 备用域取数回调成功", steps._ezd_backup_cb == true)
    check("ezd 备用域取数写同键缓存", dc.get(EZD_KEY) ~= nil)
    check("ezd 备用域数据入 sources", src ~= nil and src.data ~= nil and #src.data == 4)
    stub.ezd_fail_main = false
end

-- ---------- ezdmw：合法空结果不缓存（空 <i></i> 是有效响应，不再降级备用域） ----------
steps[49] = function()
    dc.remove(EZD_KEY)
    stub.net_calls = 0
    stub.ezd_data = EZD_EMPTY
    load_danmaku_for_ezdmw(EZD_URL, function(success, no_data)
        steps._ezd_empty_cb = success
        steps._ezd_empty_nodata = no_data
    end)
end

steps[50] = function()
    check("ezd 空结果两跳请求（主域响应即止，不试备用域）", stub.net_calls == 2)
    check("ezd 空结果不缓存", dc.get(EZD_KEY) == nil)
    check("ezd 空结果回调失败", steps._ezd_empty_cb == false)
    check("ezd 空结果带确定性无数据判定（供调度层跳过 dmku 兜底）",
        steps._ezd_empty_nodata == true)
    stub.ezd_data = EZD_XML
end

-- ---------- ezdmw：预取伴生函数走网络写同键 / TTL 命中零网络 ----------
steps[51] = function()
    dc.remove(EZD_KEY)
    stub.net_calls = 0
    prefetch_ezdmw_danmaku("102578", function(done)
        steps._ezd_pf_net = done
    end)
end

steps[52] = function()
    check("ezd 预取走网络写同键缓存",
        steps._ezd_pf_net == true and dc.get(EZD_KEY) ~= nil)
    stub.net_calls = 0
    prefetch_ezdmw_danmaku("102578", function(done)
        steps._ezd_pf_hit = done
    end)
end

steps[53] = function()
    check("ezd 预取 TTL 命中零网络", steps._ezd_pf_hit == true and stub.net_calls == 0)
end

-- ---------- girigirilove：TTL 命中零网络（单级缓存 ggl:{GVid}-{src}-{ep}，存原始 JSON；
-- ---------- 经海外备用域 .icu URL 加载——URL 提取两域均认且同键命中） ----------
local GGL_URL = "https://ani.girigirilove.com/playGV26868-1-1/"
local GGL_URL_ICU = "https://anime.girigirilove.icu/playGV26868-1-1/"
local GGL_KEY = "ggl:26868-1-1"

steps[54] = function()
    stub.ggl_page = GGL_PAGE_HTML
    stub.ggl_data = GGL_JSON
    dc.put(GGL_KEY, GGL_JSON, { type = "json", count = 3 })
    stub.net_calls = 0
    stub.loads = 0
    load_danmaku_for_ggl(GGL_URL_ICU, function(success)
        steps._ggl_hit_cb = success
    end)
end

steps[55] = function()
    local src = DANMAKU.sources[GGL_URL_ICU]
    check("ggl 命中零网络（.icu 域同键）", stub.net_calls == 0)
    check("ggl 命中回调成功", steps._ggl_hit_cb == true)
    check("ggl 命中标记 cache", DANMAKU.cache_hit == "cache")
    check("ggl 命中走 load_danmaku", stub.loads == 1)
    check("ggl 命中数据入 sources", src ~= nil and src.data ~= nil and #src.data == 3)
    check("ggl 数据字段正确（mode 2→5 顶/3→4 底、8 位色剥 alpha）",
        src and src.data[1].text == "hi" and src.data[1].time == 1.5
        and src.data[1].color == 16777215 and src.data[1].type == 1
        and src.data[2].type == 5 and src.data[2].color == 16777215
        and src.data[3].type == 4 and src.data[3].color == 16724991)
    DANMAKU.cache_hit = nil
end

-- ---------- girigirilove：未命中走网络（播放页 player_aaaa 解裸 m3u8 → POST）且写缓存 ----------
steps[56] = function()
    dc.remove(GGL_KEY)
    stub.net_calls = 0
    load_danmaku_for_ggl(GGL_URL, function() end)
end

steps[57] = function()
    local cached = dc.get(GGL_KEY)
    local src = DANMAKU.sources[GGL_URL]
    check("ggl 网络两跳请求（播放页 + getScrolling）", stub.net_calls == 2)
    check("ggl 网络成功不标 cache", DANMAKU.cache_hit == nil)
    check("ggl POST body 为解码后裸 m3u8",
        stub.ggl_body == '{"play_url":"' .. GGL_M3U8 .. '"}', tostring(stub.ggl_body))
    check("ggl 原始 JSON 写缓存 roundtrip", cached ~= nil and cached.payload == GGL_JSON)
    check("ggl 缓存 meta 计数", cached ~= nil and cached.meta ~= nil and cached.meta.count == 3)
    check("ggl 网络数据入 sources", src ~= nil and src.data ~= nil and #src.data == 3
        and src.data[3].type == 4)
end

-- ---------- girigirilove：断网回退过期缓存（播放页请求失败即走过期兜底） ----------
steps[58] = function()
    dc_setup(function() return os.time() + 7200 end)
    stub.net_calls = 0
    stub.loads = 0
    stub.fail = true
    load_danmaku_for_ggl(GGL_URL, function(success)
        steps._ggl_stale_cb = success
    end)
end

steps[59] = function()
    check("ggl 断网播放页请求失败（不再 POST 弹幕）", stub.net_calls == 1)
    check("ggl 断网走过期缓存加载", stub.loads == 1)
    check("ggl 断网标记 stale", DANMAKU.cache_hit == "stale")
    check("ggl 断网回调成功", steps._ggl_stale_cb == true)
    DANMAKU.cache_hit = nil
    stub.fail = false
end

-- ---------- girigirilove：接口错误（code≠1）与网络失败同口径走过期兜底 ----------
steps[60] = function()
    stub.net_calls = 0
    stub.loads = 0
    stub.ggl_data = GGL_ERR
    load_danmaku_for_ggl(GGL_URL, function(success)
        steps._ggl_err_cb = success
    end)
end

steps[61] = function()
    check("ggl 接口错误两跳请求（播放页 + POST 均达）", stub.net_calls == 2)
    check("ggl 接口错误走过期缓存兜底", stub.loads == 1 and DANMAKU.cache_hit == "stale"
        and steps._ggl_err_cb == true)
    DANMAKU.cache_hit = nil
    stub.ggl_data = GGL_JSON
end

-- ---------- girigirilove：合法空结果不缓存（code=1 空表是有效响应） ----------
steps[62] = function()
    dc.remove(GGL_KEY)
    dc_setup()
    stub.net_calls = 0
    stub.ggl_data = GGL_EMPTY
    load_danmaku_for_ggl(GGL_URL, function(success)
        steps._ggl_empty_cb = success
    end)
end

steps[63] = function()
    check("ggl 空结果两跳请求", stub.net_calls == 2)
    check("ggl 空结果不缓存", dc.get(GGL_KEY) == nil)
    check("ggl 空结果回调失败", steps._ggl_empty_cb == false)
    stub.ggl_data = GGL_JSON
end

-- ---------- girigirilove：预取伴生函数走网络写同键 / TTL 命中零网络 ----------
steps[64] = function()
    stub.net_calls = 0
    prefetch_ggl_danmaku("26868", 1, 1, function(done)
        steps._ggl_pf_net = done
    end)
end

steps[65] = function()
    check("ggl 预取走网络写同键缓存",
        steps._ggl_pf_net == true and dc.get(GGL_KEY) ~= nil)
    stub.net_calls = 0
    prefetch_ggl_danmaku("26868", 1, 1, function(done)
        steps._ggl_pf_hit = done
    end)
end

steps[66] = function()
    check("ggl 预取 TTL 命中零网络", steps._ggl_pf_hit == true and stub.net_calls == 0)
end

-- ---------- aiyifan：TTL 命中零网络（单级缓存 ayf:{mediaKey}:{videoId}，存原始 JSON；
-- ---------- 签名密钥未引导亦零网络——缓存命中不触发 home/config） ----------
local AYF_URL = "https://www.yfsp.tv/play/aIEHicrw641?id=OUOLuGAsKu5&videoId=912438&videoType=1"
local AYF_KEY = "ayf:aIEHicrw641:912438"
-- 站点原生链接形态（网页集数链接不带 videoId，经 VideoDetails 补齐 uniqueID）
local AYF_NATIVE_URL = "https://www.yfsp.tv/play/bIEHicrw642?id=EPKEY2"
local AYF_KEY2 = "ayf:bIEHicrw642:999888"

-- 从捕获的 curl args 提取首个指定请求头值
local function ayf_header(args, name)
    for i = 1, #args - 1 do
        if args[i] == "-H" and args[i + 1]:sub(1, #name + 2) == name .. ": " then
            return args[i + 1]:sub(#name + 3)
        end
    end
    return nil
end

local function ayf_find_call(pattern)
    for _, c in ipairs(stub.ayf_calls) do
        if c.url:find(pattern) then return c end
    end
    return nil
end

steps[67] = function()
    stub.ayf_config = AYF_CONFIG
    stub.ayf_data = AYF_JSON
    stub.ayf_details = AYF_DETAILS
    dc.put(AYF_KEY, AYF_JSON, { type = "json", count = 3 })
    stub.net_calls = 0
    stub.loads = 0
    load_danmaku_for_aiyifan(AYF_URL, function(success)
        steps._ayf_hit_cb = success
    end)
end

steps[68] = function()
    local src = DANMAKU.sources[AYF_URL]
    check("ayf 命中零网络（签名密钥未引导）", stub.net_calls == 0)
    check("ayf 命中回调成功", steps._ayf_hit_cb == true)
    check("ayf 命中标记 cache", DANMAKU.cache_hit == "cache")
    check("ayf 命中走 load_danmaku", stub.loads == 1)
    check("ayf 命中数据入 sources", src ~= nil and src.data ~= nil and #src.data == 3)
    check("ayf 数据字段正确（position 1→5顶/2→4底、content 备选）",
        src and src.data[1].text == "hi" and src.data[1].time == 1.5
            and src.data[1].color == 16777215 and src.data[1].type == 1
            and src.data[2].type == 5 and src.data[2].color == 65280
            and src.data[3].type == 4 and src.data[3].color == 16711680
            and src.data[3].text == "底（content备选）")
    DANMAKU.cache_hit = nil
end

-- ---------- aiyifan：断网·密钥引导失败即过期兜底（时钟前移 2h 使条目过期） ----------
steps[69] = function()
    dc_setup(function() return os.time() + 7200 end)
    stub.net_calls = 0
    stub.loads = 0
    stub.ayf_calls = {}
    stub.fail = true
    load_danmaku_for_aiyifan(AYF_URL, function(success)
        steps._ayf_cfgfail_cb = success
    end)
end

steps[70] = function()
    check("ayf 引导失败单请求（不重试不取弹幕）", stub.net_calls == 1
        and stub.ayf_calls[1] ~= nil and stub.ayf_calls[1].url:find("api/home/config") ~= nil)
    check("ayf 引导失败走过期缓存加载", stub.loads == 1)
    check("ayf 引导失败标记 stale", DANMAKU.cache_hit == "stale")
    check("ayf 引导失败回调成功", steps._ayf_cfgfail_cb == true)
    DANMAKU.cache_hit = nil
    stub.fail = false
    dc_setup()
end

-- ---------- aiyifan：未命中走网络（home/config 引导 → 签名 GetBarrages）且写缓存 ----------
steps[71] = function()
    dc.remove(AYF_KEY)
    stub.net_calls = 0
    stub.ayf_calls = {}
    load_danmaku_for_aiyifan(AYF_URL, function() end)
end

steps[72] = function()
    local cached = dc.get(AYF_KEY)
    local roundtrip = cached and utils.parse_json(cached.payload)
    check("ayf 网络两跳请求（引导 + 弹幕）", stub.net_calls == 2
        and #stub.ayf_calls == 2)
    check("ayf 网络成功不标 cache", DANMAKU.cache_hit == nil)
    check("ayf 引导默认私钥签名（x-pub 空串）", (function()
        local c = ayf_find_call("api/home/config")
        local ts = c and ayf_header(c.args, "x-timestamp")
        local query = c and c.url:match("%?(.+)$")
        return c ~= nil and ts ~= nil and query == "_t=" .. ts
            and ayf_header(c.args, "x-pub") == ""
            and ayf_header(c.args, "x-sign") == md5.sum(query .. ts .. "57688*1-331@")
    end)())
    check("ayf 弹幕签名头与 URL query 按序", (function()
        local c = ayf_find_call("GetBarrages")
        local ts = c and ayf_header(c.args, "x-timestamp")
        local query = c and c.url:match("%?(.+)$")
        return c ~= nil and query == "mediaKey=aIEHicrw641&videoId=912438&videoType=1"
            and ayf_header(c.args, "x-pub") == "testpub123"
            and ayf_header(c.args, "x-sign") == md5.sum(query .. ts .. "testpriv456")
    end)())
    check("ayf 原始 JSON 写缓存 roundtrip", cached ~= nil
        and roundtrip ~= nil and type(roundtrip.data) == "table"
        and type(roundtrip.data.list) == "table" and #roundtrip.data.list == 3)
    check("ayf 缓存 meta 计数", cached ~= nil and cached.meta ~= nil and cached.meta.count == 3)
end

-- ---------- aiyifan：老链接缺 videoId（VideoDetails 补齐 → 同键写缓存；二次加载 TTL 命中，
-- ---------- 仍付一次详情 GET——无映射缓存为既定取舍） ----------
steps[73] = function()
    stub.net_calls = 0
    stub.ayf_calls = {}
    load_danmaku_for_aiyifan(AYF_NATIVE_URL, function(success)
        steps._ayf_native_cb = success
    end)
end

steps[74] = function()
    local src = DANMAKU.sources[AYF_NATIVE_URL]
    check("ayf 老链接两跳请求（详情 + 弹幕；密钥内存命中）", stub.net_calls == 2)
    check("ayf 详情 query 按序（mediaKey&videoType&episodeKey）", (function()
        local c = ayf_find_call("VideoDetails")
        local query = c and c.url:match("%?(.+)$")
        return c ~= nil and query == "mediaKey=bIEHicrw642&videoType=1&episodeKey=EPKEY2"
    end)())
    check("ayf 老链接补齐 uniqueID 后写同键缓存", steps._ayf_native_cb == true
        and dc.get(AYF_KEY2) ~= nil)
    check("ayf 老链接数据入 sources", src ~= nil and src.data ~= nil and #src.data == 3)
    stub.net_calls = 0
    stub.ayf_calls = {}
    load_danmaku_for_aiyifan(AYF_NATIVE_URL, function() end)
end

steps[75] = function()
    check("ayf 老链接二次加载详情单跳（弹幕 TTL 命中零网络）",
        stub.net_calls == 1 and stub.ayf_calls[1].url:find("VideoDetails") ~= nil
            and DANMAKU.cache_hit == "cache")
    DANMAKU.cache_hit = nil
end

-- ---------- aiyifan：合法空结果不缓存（ret=200 空表；密钥内存命中仅弹幕单跳） ----------
steps[76] = function()
    dc.remove(AYF_KEY2)
    stub.net_calls = 0
    stub.ayf_calls = {}
    stub.ayf_data = AYF_EMPTY
    load_danmaku_for_aiyifan(AYF_NATIVE_URL, function(success)
        steps._ayf_empty_cb = success
    end)
end

steps[77] = function()
    check("ayf 空结果两跳请求（详情 + 弹幕；密钥内存命中）", stub.net_calls == 2
        and stub.ayf_calls[2] ~= nil and stub.ayf_calls[2].url:find("GetBarrages") ~= nil)
    check("ayf 空结果不缓存", dc.get(AYF_KEY2) == nil)
    check("ayf 空结果回调失败", steps._ayf_empty_cb == false)
    stub.ayf_data = AYF_JSON
    -- 为接口错误的过期兜底场景准备条目（真实时钟写入，随后时钟前移使之过期）
    dc.put(AYF_KEY, AYF_JSON, { type = "json", count = 3 })
end

-- ---------- aiyifan：接口错误 ret≠200 强刷密钥重试一次仍败 → 过期兜底 ----------
steps[78] = function()
    dc_setup(function() return os.time() + 7200 end)
    stub.net_calls = 0
    stub.loads = 0
    stub.ayf_calls = {}
    stub.ayf_data = AYF_ERR
    load_danmaku_for_aiyifan(AYF_URL, function(success)
        steps._ayf_err_cb = success
    end)
end

steps[79] = function()
    check("ayf 接口错误三跳请求（弹幕 → 强刷密钥 → 弹幕重试）", stub.net_calls == 3
        and #stub.ayf_calls == 3
        and stub.ayf_calls[1].url:find("GetBarrages") ~= nil
        and stub.ayf_calls[2].url:find("api/home/config") ~= nil
        and stub.ayf_calls[3].url:find("GetBarrages") ~= nil)
    check("ayf 接口错误走过期缓存兜底", stub.loads == 1 and DANMAKU.cache_hit == "stale"
        and steps._ayf_err_cb == true)
    DANMAKU.cache_hit = nil
    stub.ayf_data = AYF_JSON
end

-- ---------- aiyifan：断网·弹幕网络失败不重试不刷密钥 → 过期兜底 ----------
steps[80] = function()
    stub.net_calls = 0
    stub.ayf_calls = {}
    stub.loads = 0
    stub.fail = true
    load_danmaku_for_aiyifan(AYF_URL, function(success)
        steps._ayf_netfail_cb = success
    end)
end

steps[81] = function()
    check("ayf 断网弹幕单请求（密钥内存命中不刷新）", stub.net_calls == 1
        and stub.ayf_calls[1] ~= nil and stub.ayf_calls[1].url:find("GetBarrages") ~= nil)
    check("ayf 断网走过期缓存加载", stub.loads == 1 and DANMAKU.cache_hit == "stale"
        and steps._ayf_netfail_cb == true)
    DANMAKU.cache_hit = nil
    stub.fail = false
    dc_setup()
end

-- ---------- aiyifan：预取伴生函数走网络写同键 / TTL 命中零网络 ----------
steps[82] = function()
    dc.remove(AYF_KEY)
    stub.net_calls = 0
    prefetch_aiyifan_danmaku("aIEHicrw641", "912438", "1", function(done)
        steps._ayf_pf_net = done
    end)
end

steps[83] = function()
    check("ayf 预取走网络写同键缓存",
        steps._ayf_pf_net == true and dc.get(AYF_KEY) ~= nil)
    stub.net_calls = 0
    prefetch_aiyifan_danmaku("aIEHicrw641", "912438", "1", function(done)
        steps._ayf_pf_hit = done
    end)
end

steps[84] = function()
    check("ayf 预取 TTL 命中零网络", steps._ayf_pf_hit == true and stub.net_calls == 0)
end

-- ---------- ezdmw 补充：播放页无弹幕播放器（第三方解析源）→ 确定性无弹幕 ----------
-- 播放页取到但无 danmuku iframe：不是网络失败——不消费过期缓存、不取 getData、
-- 如实提示无弹幕、回调带 no_data 判定（调度层据此跳过 dmku 兜底，免误导性报错）
steps[85] = function()
    dc.remove(EZD_KEY)
    stub.net_calls = 0
    stub.loads = 0
    stub.ezd_page = EZD_NOPLAYER_HTML
    load_danmaku_for_ezdmw(EZD_URL, function(success, no_data)
        steps._ezd_np_cb = success
        steps._ezd_np_nodata = no_data
    end)
end

steps[86] = function()
    check("ezd 无播放器仅播放页一跳（不取 getData）", stub.net_calls == 1)
    check("ezd 无播放器回调失败且带 no_data 判定",
        steps._ezd_np_cb == false and steps._ezd_np_nodata == true)
    check("ezd 无播放器如实提示无弹幕", #msgs > 0 and msgs[#msgs]:find("无弹幕", 1, true) ~= nil)
    check("ezd 无播放器不落源", stub.loads == 0)
    check("ezd 无播放器不写缓存", dc.get(EZD_KEY) == nil)
    -- 预取伴生函数同口径：无播放器即失败，不取 getData
    stub.net_calls = 0
    prefetch_ezdmw_danmaku("102578", function(done)
        steps._ezd_pf_np = done
    end)
end

steps[87] = function()
    check("ezd 预取无播放器失败且仅一跳",
        steps._ezd_pf_np == false and stub.net_calls == 1)
    stub.ezd_page = EZD_PAGE_HTML
end

-- ---------- 弹幕源统计留痕：失败原因第三参透传与 per-source 缓存标注 ----------
-- 各站失败回调统一 callback(ok, no_data, reason)；缓存命中经 note_cache 写台账
-- e.cache（统计菜单数据源；无 ensure 条目时仅写全局标量——既有行为）
steps[88] = function()
    dc_setup()
    stub.fail = false
    stub.net_calls = 0
    -- ezd 无弹幕播放器：no_data 判定 + 具体原因
    stub.ezd_page = EZD_NOPLAYER_HTML
    dc.remove(EZD_KEY)
    load_danmaku_for_ezdmw(EZD_URL, function(success, no_data, reason)
        steps._st_ezd_ok, steps._st_ezd_nodata, steps._st_ezd_reason = success, no_data, reason
    end)
end

steps[89] = function()
    check("统计·ezd无播放器带具体原因", steps._st_ezd_ok == false
        and steps._st_ezd_nodata == true
        and steps._st_ezd_reason ~= nil
        and steps._st_ezd_reason:find("无弹幕", 1, true) ~= nil,
        steps._st_ezd_reason)
    -- ggl 接口错误（code≠1）：网络失败口径原因
    stub.ezd_page = EZD_PAGE_HTML
    stub.ggl_page = GGL_PAGE_HTML
    stub.ggl_data = GGL_ERR
    dc.remove(GGL_KEY)
    load_danmaku_for_ggl(GGL_URL, function(success, no_data, reason)
        steps._st_ggl_ok, steps._st_ggl_reason = success, reason
    end)
end

steps[90] = function()
    check("统计·ggl接口错误带原因", steps._st_ggl_ok == false
        and steps._st_ggl_reason ~= nil and steps._st_ggl_reason ~= "",
        steps._st_ggl_reason)
    -- animeko 断网且无过期缓存：网络失败原因
    stub.fail = true
    load_danmaku_for_animeko("https://api.animeko.org/episode/778899", function(success, no_data, reason)
        steps._st_ako_ok, steps._st_ako_reason = success, reason
    end)
end

steps[91] = function()
    check("统计·ako断网带网络失败原因", steps._st_ako_ok == false
        and steps._st_ako_reason ~= nil
        and steps._st_ako_reason:find("网络失败", 1, true) ~= nil,
        steps._st_ako_reason)
    stub.fail = false
    -- 缓存命中（先 ensure 建台账条目）：e.cache 标注
    source_status.reset()
    source_status.ensure(AKO_URL, "animeko")
    dc.put(AKO_KEY, AKO_JSON, { type = "json", count = 2 })
    load_danmaku_for_animeko(AKO_URL, function() end)
end

steps[92] = function()
    local e = nil
    for _, x in ipairs(source_status.snapshot().entries) do
        if x.key == AKO_URL then e = x end
    end
    check("统计·命中标注e.cache=cache", e ~= nil and e.cache == "cache",
        e and tostring(e.cache))
    source_status.reset()
    DANMAKU.cache_hit = nil
end

-- ---------- 次元城：TTL 命中零网络（单级缓存 cyc:{videoId}-{集序号}，存原始 JSON；
-- ---------- 经粘贴网页 URL（带 ?from=cychub 查询参数）加载——路径匹配忽略 query 同键命中） ----------
local CYC_URL = "https://www.cycani.org/anime/2964/play/1"
local CYC_URL_WEB = "https://www.cycani.org/anime/2964/play/1?from=cychub"
local CYC_URL_EP2 = "https://www.cycani.org/anime/2964/play/2"
local CYC_KEY = "cyc:2964-1"
-- 分集表单页（5 集，page1 即取满 pager.total=5）
local CYC_SECTIONS_JSON = (function()
    local eps = {}
    for i = 1, 5 do
        eps[#eps + 1] = ('{"id":%d,"title":"第%02d集"}'):format(40100 + i - 1, i)
    end
    return '{"code":0,"data":{"list":[' .. table.concat(eps, ",")
        .. '],"pager":{"page":1,"page_size":100,"total":5}}}'
end)()
-- 弹幕：normal→1 滚动 / top→5 顶（防御性映射）、十进制色原样（65280=0x00FF00）
local CYC_JSON = '{"code":0,"data":{"count":2,"items":['
    .. '{"id":1,"content":"hi","time_point":1.5,"mode":"normal","color":16777215},'
    .. '{"id":2,"content":"顶","time_point":2.5,"mode":"top","color":65280}]}}'
local CYC_EMPTY = '{"code":0,"data":{"count":0,"items":[]}}'
local CYC_ERR = '{"code":1000,"msg":"app_name is required"}'

steps[93] = function()
    dc.put(CYC_KEY, CYC_JSON, { type = "json", count = 2 })
    stub.net_calls = 0
    stub.loads = 0
    load_danmaku_for_cyc(CYC_URL_WEB, function(success)
        steps._cyc_hit_cb = success
    end)
end

steps[94] = function()
    local src = DANMAKU.sources[CYC_URL_WEB]
    check("cyc 命中零网络（粘贴 ?from= URL 同键）", stub.net_calls == 0)
    check("cyc 命中回调成功", steps._cyc_hit_cb == true)
    check("cyc 命中标记 cache", DANMAKU.cache_hit == "cache")
    check("cyc 命中走 load_danmaku", stub.loads == 1)
    check("cyc 命中数据入 sources", src ~= nil and src.data ~= nil and #src.data == 2)
    check("cyc 数据字段正确（mode top→5、十进制色原样）",
        src and src.data[1].text == "hi" and src.data[1].time == 1.5
        and src.data[1].color == 16777215 and src.data[1].type == 1
        and src.data[2].type == 5 and src.data[2].color == 65280)
    DANMAKU.cache_hit = nil
end

-- ---------- 次元城：未命中走网络（分集表定位 section_id → GET danmaku）且写缓存 ----------
steps[95] = function()
    dc.remove(CYC_KEY)
    stub.cyc_sections = CYC_SECTIONS_JSON
    stub.cyc_data = CYC_JSON
    stub.cyc_calls = {}
    stub.net_calls = 0
    load_danmaku_for_cyc(CYC_URL, function() end)
end

steps[96] = function()
    local cached = dc.get(CYC_KEY)
    local src = DANMAKU.sources[CYC_URL]
    check("cyc 网络两跳请求（分集表 + danmaku）", stub.net_calls == 2)
    check("cyc 网络成功不标 cache", DANMAKU.cache_hit == nil)
    -- 分集表与弹幕请求均携带唯一必需头 x-app-name: cyc_web（接口实测缺头即 1000）
    local header_ok = #stub.cyc_calls == 2
    for _, call in ipairs(stub.cyc_calls) do
        local found = false
        for i = 1, #call.args - 1 do
            if call.args[i] == "-H" and call.args[i + 1] == "x-app-name: cyc_web" then
                found = true break
            end
        end
        if not found then header_ok = false end
    end
    check("cyc 两跳均带 x-app-name 头", header_ok)
    -- 弹幕请求定位首集 section_id=40100（分集表 list[1]）
    check("cyc 弹幕按 section_id 请求",
        stub.cyc_calls[2] ~= nil and stub.cyc_calls[2].url:find("/api/sections/40100/danmaku") ~= nil,
        stub.cyc_calls[2] and stub.cyc_calls[2].url)
    check("cyc 原始 JSON 写缓存 roundtrip", cached ~= nil and cached.payload == CYC_JSON)
    check("cyc 缓存 meta 计数", cached ~= nil and cached.meta ~= nil and cached.meta.count == 2)
    check("cyc 网络数据入 sources", src ~= nil and src.data ~= nil and #src.data == 2)
end

-- ---------- 次元城：分集表会话缓存——同番换集仅弹幕单跳 ----------
steps[97] = function()
    stub.cyc_calls = {}
    stub.net_calls = 0
    load_danmaku_for_cyc(CYC_URL_EP2, function(success)
        steps._cyc_ep2_cb = success
    end)
end

steps[98] = function()
    check("cyc 换集单跳（分集表会话缓存命中）", stub.net_calls == 1)
    check("cyc 换集弹幕定位第2集 sid=40101",
        stub.cyc_calls[1] ~= nil and stub.cyc_calls[1].url:find("/api/sections/40101/danmaku") ~= nil,
        stub.cyc_calls[1] and stub.cyc_calls[1].url)
    check("cyc 换集回调成功", steps._cyc_ep2_cb == true)
    check("cyc 换集写独立键", dc.get("cyc:2964-2") ~= nil)
end

-- ---------- 次元城：长番串行翻页（page_size=100 取满 pager.total=250 → 3 页） ----------
steps[99] = function()
    local function page_json(page, n, total)
        local eps = {}
        for i = 1, n do
            eps[#eps + 1] = ('{"id":%d,"title":"第%03d集"}')
                :format((page - 1) * 100 + i, (page - 1) * 100 + i)
        end
        return '{"code":0,"data":{"list":[' .. table.concat(eps, ",")
            .. ('],"pager":{"page":%d,"page_size":100,"total":%d}}}'):format(page, total)
    end
    stub.cyc_sections_pages = { ["780"] = { page_json(1, 100, 250), page_json(2, 100, 250), page_json(3, 50, 250) } }
    stub.cyc_calls = {}
    stub.net_calls = 0
    load_danmaku_for_cyc("https://www.cycani.org/anime/780/play/150", function(success)
        steps._cyc_long_cb = success
    end)
end

steps[100] = function()
    -- 3 页分集表 + 1 次弹幕；第 150 集 → sid=150（翻页跨页定位）
    check("cyc 长番翻页 3+1 四跳请求", stub.net_calls == 4,
        ("got %d"):format(stub.net_calls))
    check("cyc 翻页页码顺序 1→2→3", stub.cyc_calls[1] ~= nil
        and stub.cyc_calls[1].url:find("page=1") ~= nil
        and stub.cyc_calls[2] ~= nil and stub.cyc_calls[2].url:find("page=2") ~= nil
        and stub.cyc_calls[3] ~= nil and stub.cyc_calls[3].url:find("page=3") ~= nil)
    check("cyc 跨页定位第150集 sid=150",
        stub.cyc_calls[4] ~= nil and stub.cyc_calls[4].url:find("/api/sections/150/") ~= nil,
        stub.cyc_calls[4] and stub.cyc_calls[4].url)
    check("cyc 长番回调成功且写键", steps._cyc_long_cb == true
        and dc.get("cyc:780-150") ~= nil)
    stub.cyc_sections_pages = nil
end

-- ---------- 次元城：断网回退过期缓存（分集表请求失败即走过期兜底） ----------
steps[101] = function()
    dc.put("cyc:777-1", CYC_JSON, { type = "json", count = 2 })
    dc_setup(function() return os.time() + 7200 end)
    stub.net_calls = 0
    stub.loads = 0
    stub.fail = true
    load_danmaku_for_cyc("https://www.cycani.org/anime/777/play/1", function(success)
        steps._cyc_stale_cb = success
    end)
end

steps[102] = function()
    check("cyc 断网分集表请求失败（无会话缓存整链一跳即止）", stub.net_calls == 1)
    check("cyc 断网走过期缓存加载", stub.loads == 1 and DANMAKU.cache_hit == "stale"
        and steps._cyc_stale_cb == true)
    DANMAKU.cache_hit = nil
    stub.fail = false
end

-- ---------- 次元城：接口错误（code≠0）与网络失败同口径走过期兜底 ----------
steps[103] = function()
    stub.net_calls = 0
    stub.loads = 0
    stub.cyc_data = CYC_ERR
    -- vid=2964 分集表会话缓存命中，仅弹幕一跳；cyc:2964-1 缓存已在过期窗口（get_stale 可取）
    load_danmaku_for_cyc(CYC_URL, function(success)
        steps._cyc_err_cb = success
    end)
end

steps[104] = function()
    check("cyc 接口错误单跳请求（分集表会话缓存）", stub.net_calls == 1)
    check("cyc 接口错误走过期缓存兜底", stub.loads == 1 and DANMAKU.cache_hit == "stale"
        and steps._cyc_err_cb == true)
    DANMAKU.cache_hit = nil
    stub.cyc_data = CYC_JSON
    dc_setup()
end

-- ---------- 次元城：合法空结果不缓存（code=0 空 items 是有效响应） ----------
steps[105] = function()
    dc.remove(CYC_KEY)
    stub.net_calls = 0
    stub.cyc_data = CYC_EMPTY
    load_danmaku_for_cyc(CYC_URL, function(success, no_data)
        steps._cyc_empty_cb = success
        steps._cyc_empty_nodata = no_data
    end)
end

steps[106] = function()
    check("cyc 空结果单跳请求", stub.net_calls == 1)
    check("cyc 空结果不缓存", dc.get(CYC_KEY) == nil)
    check("cyc 空结果回调失败且非 no_data（仍可走 dmku 兜底链）",
        steps._cyc_empty_cb == false and steps._cyc_empty_nodata == nil)
    stub.cyc_data = CYC_JSON
end

-- ---------- 次元城：集数越界确定性无弹幕（no_data 判定、不消费过期缓存） ----------
steps[107] = function()
    dc.put("cyc:2964-99", CYC_JSON, { type = "json", count = 2 })
    dc_setup(function() return os.time() + 7200 end)
    stub.net_calls = 0
    stub.loads = 0
    load_danmaku_for_cyc("https://www.cycani.org/anime/2964/play/99", function(success, no_data, reason)
        steps._cyc_oob = { success, no_data, reason }
    end)
end

steps[108] = function()
    -- 分集表会话缓存命中零网络；第 99 集不存在（共 5 集）→ no_data 终态
    check("cyc 越界零网络（会话缓存定位）", stub.net_calls == 0)
    check("cyc 越界 no_data 判定", steps._cyc_oob ~= nil and steps._cyc_oob[1] == false
        and steps._cyc_oob[2] == true)
    check("cyc 越界 reason 带集数信息", steps._cyc_oob ~= nil
        and tostring(steps._cyc_oob[3]):find("99") ~= nil, steps._cyc_oob and steps._cyc_oob[3])
    check("cyc 越界不消费过期缓存", stub.loads == 0 and DANMAKU.cache_hit == nil)
    dc.remove("cyc:2964-99")
    dc_setup()
end

-- ---------- 次元城：预取伴生函数走网络写同键 / TTL 命中零网络 ----------
steps[109] = function()
    stub.net_calls = 0
    prefetch_cyc_danmaku("2964", 3, function(done)
        steps._cyc_pf_net = done
    end)
end

steps[110] = function()
    check("cyc 预取走网络写同键缓存（分集表会话缓存命中单跳）",
        steps._cyc_pf_net == true and stub.net_calls == 1 and dc.get("cyc:2964-3") ~= nil)
    stub.net_calls = 0
    prefetch_cyc_danmaku("2964", 3, function(done)
        steps._cyc_pf_hit = done
    end)
end

steps[111] = function()
    check("cyc 预取 TTL 命中零网络", steps._cyc_pf_hit == true and stub.net_calls == 0)
end

-- ========== OmoFun（lanerc.life，App API 逆向链路；域名发现→详情→弹幕）==========

local OMF_URL = "https://lanerc.life/vod/5001/1"
local OMF_URL_EP2 = "https://lanerc.life/vod/5001/2"
local OMF_URL_EP3 = "https://lanerc.life/vod/5001/3"
local OMF_URL_EP99 = "https://lanerc.life/vod/5001/99"
local OMF_KEY = "omf:5001-1"

-- DoH TXT 应答（dohx.lanerc.moe 实抓记录值 2026-10-15，解密即 https://v3.yyghk.com/）
local OMF_DOH_JSON = utils.format_json({ Status = 0, Answer = {
    { name = "dohx.lanerc.moe.", type = 16,
        data = '"1n4aoOeW5/QPKutimGgc78mX2D6i2yUmM2KeDK5jnRY="' } } })

-- 详情选集表（video_play_list 首选线路 12 集，resource_id 为不透明 token；
-- stub 返回完整信封——omf_env 定义在后，此处先备表）
local OMF_DETAIL_TABLE = (function()
    local eps = {}
    for i = 1, 12 do
        eps[#eps + 1] = { resource_id = ("rid5001e%02d"):format(i),
            title = ("第%02d集"):format(i) }
    end
    return {
        video_play_info = { vod_name = "测试番", vod_year = "2026", vod_total = 12 },
        video_play_list = {
            { player = "lcmain", video = eps },
            { player = "h265", video = { { resource_id = "ridB", title = "备份线路" } } },
        },
    }
end)()
local OMF_DETAIL_5002_TABLE = {
    video_play_info = { vod_total = 1 },
    video_play_list = { { video = { { resource_id = "rid5002e1", title = "第01集" } } } },
}

-- 响应体加密（自定义字母表 base64 + AES-256-ECB + PKCS7，与服务端同构——
-- 供小信封精确断言；真实密文的一致性回归在 omofun_parse_test 覆盖）
local AES_LIB = require("modules/aes")
local OMF_B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0523496781/-"
local OMF_RESP_KEY = (function()
    local t, k = {}, "8f81c2519e3b661834219e7142000093"
    for i = 1, #k do t[i - 1] = k:byte(i) end
    return t
end)()
local function omf_custom_b64_encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local b1, b2, b3 = data:byte(i), data:byte(i + 1), data:byte(i + 2)
        local has2, has3 = b2 ~= nil, b3 ~= nil
        b2, b3 = b2 or 0, b3 or 0
        local v = b1 * 65536 + b2 * 256 + b3
        -- 逐字符按 6bit 索引取
        local i1 = math.floor(v / 262144) % 64 + 1
        local i2 = math.floor(v / 4096) % 64 + 1
        local i3 = math.floor(v / 64) % 64 + 1
        local i4 = v % 64 + 1
        out[#out + 1] = OMF_B64:sub(i1, i1) .. OMF_B64:sub(i2, i2)
            .. (has2 and OMF_B64:sub(i3, i3) or "=")
            .. (has3 and OMF_B64:sub(i4, i4) or "=")
    end
    return table.concat(out)
end
local function omf_encrypt_payload(tbl)
    local plain = utils.format_json(tbl)
    local pad = 16 - #plain % 16
    plain = plain .. string.rep(string.char(pad), pad)
    return omf_custom_b64_encode(AES_LIB.ECB.encrypt(OMF_RESP_KEY, plain))
end
local function omf_env(tbl)
    return '{"code":201,"data":"' .. omf_encrypt_payload(tbl) .. '","msg":"Success"}'
end

local OMF_BARRAGE_PLAIN_3 = {
    new_barrages = {
        { id = 1, bcolor = "#ffffffff", position = 0, second = 1.5, content = "hi" },
        { id = 2, bcolor = "#ff00a0ea", position = 0, second = 2.5, content = "蓝" },
        { id = 3, bcolor = "#ffff2e2e", position = 1, second = 0.5, content = "顶" },
    },
    old_barrages = {},
}
local OMF_DATA_ENV = omf_env(OMF_BARRAGE_PLAIN_3)
local OMF_EMPTY_ENV = omf_env({ new_barrages = {}, old_barrages = {} })
local OMF_DETAIL = omf_env(OMF_DETAIL_TABLE)
local OMF_DETAIL_5002 = omf_env(OMF_DETAIL_5002_TABLE)
local OMF_ERR_ENV = '{"code":400,"data":"","msg":"请求参数解析失败"}'

-- ts 首段签名复算（真机 HAR 形态：md5("/{path}"@ts@nonce@盐)）
local function omf_verify_sign(url, path_noslash)
    local sign = url:match("[?&]sign=([^&]+)")
    if not sign then return false end
    local ts, nonce, hex = sign:match(
        "^(%d+)%-([a-z][a-z][a-z][a-z][a-z][a-z])%-([0-9a-f]+)$")
    if not ts or not hex or #hex ~= 32 then return false end
    return md5.sum("/" .. path_noslash .. "@" .. ts .. "@" .. nonce
        .. "@4x2g5efd84fb46a9") == hex
end

local function omf_call_url(i)
    local c = stub.omf_calls[i]
    return c and c.url or ""
end

local function omf_has_header(args, name, value_part)
    for _, v in ipairs(args) do
        if type(v) == "string" and v:find(name .. ": ", 1, true)
            and v:find(value_part, 1, true) then
            return true
        end
    end
    return false
end

-- ---------- omf：TTL 命中零网络（域名发现/详情定位全跳过） ----------
steps[112] = function()
    omf_debug_reset()
    dc.put("omf:7001-1", utils.format_json(OMF_BARRAGE_PLAIN_3), { type = "json", count = 3 })
    stub.net_calls = 0
    stub.loads = 0
    load_danmaku_for_omofun("https://lanerc.life/vod/7001/1", function(success)
        steps._omf_hit_cb = success
    end)
end

steps[113] = function()
    check("omf 命中零网络（域名发现未触发）", stub.net_calls == 0)
    check("omf 命中回调成功", steps._omf_hit_cb == true)
    check("omf 命中标记 cache", DANMAKU.cache_hit == "cache")
    check("omf 命中走 load_danmaku", stub.loads == 1)
    local src = DANMAKU.sources["https://lanerc.life/vod/7001/1"]
    check("omf 命中数据入 sources（3 条）", src ~= nil and #src.data == 3)
    check("omf 数据字段正确（升序/bcolor 8 位丢 alpha/position 0滚 1顶）",
        src.data[1].text == "顶" and src.data[1].time == 0.5
            and src.data[1].color == 16723502 and src.data[1].type == 5
            and src.data[2].text == "hi" and src.data[2].time == 1.5
            and src.data[2].color == 16777215 and src.data[2].type == 1
            and src.data[3].color == 41194 and src.data[3].type == 1)
    DANMAKU.cache_hit = nil
end

-- ---------- omf：DoH 发现 → 详情 → 弹幕 全链（弹幕参数 vid=vod_id&vod=集序号） ----------
steps[114] = function()
    stub.omf_doh = OMF_DOH_JSON
    stub.omf_detail = OMF_DETAIL
    stub.omf_data = OMF_DATA_ENV
    stub.omf_calls = {}
    stub.net_calls = 0
    load_danmaku_for_omofun(OMF_URL, function(success)
        steps._omf_full_cb = success
    end)
end

steps[115] = function()
    -- DoH 1 + 详情 1 + 弹幕 1
    check("omf 全链三跳（DoH→详情→弹幕）", stub.net_calls == 3)
    check("omf DoH 查询 dohx TXT", omf_call_url(1):find("name=dohx%.lanerc%.moe") ~= nil
        and omf_call_url(1):find("type=16") ~= nil)
    check("omf TXT 发现的 base 生效", omf_call_url(2):find("https://v3%.yyghk%.com/app/v2/vod/5001%?") == 1)
    check("omf 详情请求带签名", omf_verify_sign(omf_call_url(2), "app/v2/vod/5001"))
    check("omf 弹幕参数 vid=番剧id&vod=集序号", omf_call_url(3):find("vid=5001&vod=1&sign=") ~= nil)
    check("omf 弹幕请求签名（ts 首段 + / 前缀 payload）",
        omf_verify_sign(omf_call_url(3), "app/chat/barragev2"))
    check("omf 弹幕请求带 Dart UA 与三头口径",
        omf_has_header(stub.omf_calls[3].args, "User-Agent", "Dart/3.9.2 (dart:io)")
            and omf_has_header(stub.omf_calls[3].args, "Content-Type", "application/json"))
    local cached = dc.get(OMF_KEY)
    check("omf 成功写缓存（解密后明文 roundtrip）", cached ~= nil and (function()
        local p = require("modules/omofun_parse").parse_danmaku(utils.parse_json(cached.payload))
        return p.ok and #p.comments == 3
    end)())
    check("omf 全链回调成功", steps._omf_full_cb == true)
end

-- ---------- omf：换集单跳（详情会话缓存命中，弹幕按集序号直取） ----------
steps[116] = function()
    stub.omf_calls = {}
    stub.net_calls = 0
    load_danmaku_for_omofun(OMF_URL_EP2, function(success)
        steps._omf_ep2_cb = success
    end)
end

steps[117] = function()
    check("omf 换集单跳（弹幕 vod=2）", stub.net_calls == 1
        and omf_call_url(1):find("vid=5001&vod=2&sign=") ~= nil)
    check("omf 换集回调成功", steps._omf_ep2_cb == true)
end

-- ---------- omf：集数越界确定性无弹幕（不消费过期缓存、零网络） ----------
steps[118] = function()
    stub.omf_calls = {}
    stub.net_calls = 0
    load_danmaku_for_omofun(OMF_URL_EP99, function(success, no_data, reason)
        steps._omf_oob = { success, no_data, reason }
    end)
end

steps[119] = function()
    check("omf 集数越界 no_data 判定零网络（详情会话缓存）", stub.net_calls == 0
        and steps._omf_oob[1] == false and steps._omf_oob[2] == true)
    check("omf 越界原因带总集数", steps._omf_oob[3]:find("共 12 集", 1, true) ~= nil)
end

-- ---------- omf：合法空（越界集序号与无弹幕同口径空数组）不缓存 ----------
steps[120] = function()
    stub.omf_detail = OMF_DETAIL_5002
    stub.omf_data = OMF_EMPTY_ENV
    stub.omf_calls = {}
    stub.net_calls = 0
    load_danmaku_for_omofun("https://lanerc.life/vod/5002/1", function(success)
        steps._omf_empty_cb = success
    end)
end

steps[121] = function()
    check("omf 合法空两跳（详情 + 弹幕）", stub.net_calls == 2)
    check("omf 合法空不缓存", dc.get("omf:5002-1") == nil)
    check("omf 合法空如实提示无弹幕", #msgs > 0 and msgs[#msgs]:find("没有弹幕", 1, true) ~= nil)
    check("omf 合法空回调失败（非 no_data）", steps._omf_empty_cb == false)
end

-- ---------- omf：断网（弹幕环节失败）→ 过期缓存兜底 ----------
steps[122] = function()
    -- 真实时钟写入 ep3 缓存，随后时钟前移使之过期（TTL miss → 网络失败 → stale）
    dc.put("omf:5001-3", utils.format_json(OMF_BARRAGE_PLAIN_3), { type = "json", count = 3 })
    dc_setup(function() return os.time() + 7200 end)
    stub.net_calls = 0
    stub.loads = 0
    stub.fail = true
    load_danmaku_for_omofun(OMF_URL_EP3, function(success)
        steps._omf_stale_cb = success
    end)
end

steps[123] = function()
    check("omf 断网弹幕单请求（详情会话缓存命中）", stub.net_calls == 1)
    check("omf 断网走过期缓存兜底", stub.loads == 1 and DANMAKU.cache_hit == "stale"
        and steps._omf_stale_cb == true)
    DANMAKU.cache_hit = nil
    stub.fail = false
    dc_setup()
end

-- ---------- omf：弹幕接口错误（code=400 data 空串）→ 无过期缓存按失败上报 ----------
steps[124] = function()
    stub.omf_data = OMF_ERR_ENV
    stub.omf_calls = {}
    stub.net_calls = 0
    load_danmaku_for_omofun("https://lanerc.life/vod/5001/4", function(success)
        steps._omf_err_cb = success
    end)
end

steps[125] = function()
    check("omf 接口错误单请求", stub.net_calls == 1
        and omf_call_url(1):find("barragev2") ~= nil)
    check("omf 接口错误无过期缓存按失败上报", steps._omf_err_cb == false
        and dc.get("omf:5001-4") == nil)
    stub.omf_data = OMF_DATA_ENV  -- 还原（S4 曾换空信封）
end

-- ---------- omf：预取同键写缓存 / TTL 命中零网络 ----------
steps[126] = function()
    stub.omf_calls = {}
    stub.net_calls = 0
    prefetch_omofun_danmaku("5001", 5, function(done)
        steps._omf_pf_net = done
    end)
end

steps[127] = function()
    check("omf 预取走网络写同键缓存（详情会话缓存命中单跳）",
        steps._omf_pf_net == true and stub.net_calls == 1
            and omf_call_url(1):find("vid=5001&vod=5&sign=") ~= nil and dc.get("omf:5001-5") ~= nil)
    stub.net_calls = 0
    prefetch_omofun_danmaku("5001", 5, function(done)
        steps._omf_pf_hit = done
    end)
end

steps[128] = function()
    check("omf 预取 TTL 命中零网络", steps._omf_pf_hit == true and stub.net_calls == 0)
end

-- ---------- omf：DoH 全失败走内置兜底 base ----------
steps[129] = function()
    omf_debug_reset()
    stub.omf_doh = nil  -- 两家公共 DoH 均不可达
    stub.omf_detail = OMF_DETAIL  -- 还原（S4 曾换 5002 详情）
    stub.omf_calls = {}
    stub.net_calls = 0
    load_danmaku_for_omofun("https://lanerc.life/vod/5001/6", function(success)
        steps._omf_fallback_cb = success
    end)
end

steps[130] = function()
    -- DoH 2（全失败）+ 详情 + 弹幕各 1（走内置兜底 base https://v3.yyghk.com）
    check("omf DoH 失败走内置兜底 base（四跳）", stub.net_calls == 4)
    check("omf 兜底 base 业务请求可达",
        omf_call_url(3):find("https://v3%.yyghk%.com/app/v2/vod/5001%?") == 1
            and omf_call_url(4):find("https://v3%.yyghk%.com/app/chat/barragev2") == 1)
    check("omf 兜底链回调成功", steps._omf_fallback_cb == true)
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
