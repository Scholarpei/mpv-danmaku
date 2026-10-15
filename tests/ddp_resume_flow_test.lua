-- dandanplay 续载校验流程测试（apis/dandanplay.lua resume_dandanplay_episode 链路）
-- stub make_danmaku_request_args/call_cmd_async/write_history 等，直打续载入口状态机：
--   命中（真实 episodeId/episodeTitle/meta 全链）/ 越界诚实失败（不写 history、台账留痕、
--   兜底搜索消息）/ 网络失败回退旧算术（显示标注未校验）/ 迟到回调防护（换集放弃）/
--   占位换键（extra:ddp → 真实 comment URL）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

-- ---- 打桩（运行时按全局查找）----
show_message = function(msg) end
load_danmaku = function() end
DANMAKU = { sources = {}, count = 1 }

local STUB_PATH = "E:/Anime/Amagami/[VCB-Studio] Amagami SS 26.mkv"
local STUB = { path = nil }
mp.get_property = function(name, default)
    if name == "path" then return STUB.path or STUB_PATH end
    return default
end

local wh = {}          -- write_history 记参
write_history = function(episodeid, server)
    wh[#wh + 1] = { episodeid = episodeid, server = server,
        episode = DANMAKU.episode, anime = DANMAKU.anime }
end
set_danmaku_button = function() end

local msgs = {}        -- script-message 记录（auto_load_fallback 断言）
local real_commandv = mp.commandv
mp.commandv = function(...)
    local args = { ... }
    msgs[#msgs + 1] = table.concat(args, "|")
    return real_commandv(...)
end

require("modules/options")
options.api_server = "https://api.example.com"
require("modules/utils")
require("modules/parse")
require("modules/guess")
require("apis/dandanplay")
local source_status = require("modules/source_status")

-- 网络桩：按 URL 分发（bangumi 分集表 / comment 弹幕）
local SERVER = "https://api.example.com"
local net = { calls = {}, fail_all = false, bangumi = nil }

make_danmaku_request_args = function(method, url) return { url } end
call_cmd_async = function(args, cb)
    local url = args[#args]
    net.calls[#net.calls + 1] = url
    mp.add_timeout(0.01, function()
        if net.fail_all then
            cb("curl: (7) Failed to connect", nil)
            return
        end
        if url:find("/api/v2/bangumi/", 1, true) then
            cb(nil, net.bangumi)
        elseif url:find("/api/v2/comment/", 1, true) then
            cb(nil, '{"count":2,"comments":['
                .. '{"p":"1.00,1,16777215,1,0,0,0","m":"a"},'
                .. '{"p":"2.00,4,9830415,1,0,0,0","m":"b"}]}')
        else
            cb("unexpected url: " .. tostring(url), nil)
        end
    end)
end

-- 圣诞之吻SS 实测形状（bangumiId 7506，episodeId=7506×10000+N，25 集）
local function amagami_bangumi_json(n)
    n = n or 25
    local eps = {}
    for i = 1, n do
        eps[#eps + 1] = string.format(
            '{"episodeId":%d,"episodeTitle":"第%d话 副标题%d","episodeNumber":"%d"}',
            75060000 + i, i, i, i)
    end
    return '{"errorCode":0,"success":true,"bangumi":{"titles":'
        .. '[{"language":"主标题","title":"圣诞之吻SS"},{"language":"官方标题，简体中文","title":"圣诞之吻SS"}],'
        .. '"episodes":[' .. table.concat(eps, ",") .. ']}}'
end

local function snapshot_find(key)
    for _, e in ipairs(source_status.snapshot().entries) do
        if e.key == key then return e end
    end
    return nil
end

local steps = {}

-- ---------- 用例 1：命中（锚 ep13 +1 → ep14 真实标题全链） ----------
steps[1] = function()
    net.bangumi = amagami_bangumi_json()
    source_status.begin({
        { key = "extra:ddp", provider = "ddp", anime = "历史记录的旧标题" },
    })
    resume_dandanplay_episode(75060013, 1, SERVER, "第14话", STUB_PATH)
end

steps[2] = function()
    local url = SERVER .. "/api/v2/comment/75060014?withRelated=true&chConvert=0"
    check("命中：write_history 收到真实 episodeId", #wh == 1 and wh[1].episodeid == 75060014)
    check("命中：history 快照为源端真实标题",
        wh[1].episode == "第14话 副标题14" and wh[1].anime == "圣诞之吻SS")
    check("命中：DANMAKU.episode 为真实标题", DANMAKU.episode == "第14话 副标题14")
    check("命中：源条目标题为真实标题（meta 落源）",
        DANMAKU.sources[url] ~= nil and DANMAKU.sources[url].episode_title == "第14话 副标题14")
    check("命中：源条目动画标题取自主标题",
        DANMAKU.sources[url].anime_title == "圣诞之吻SS")
    check("命中：无兜底搜索消息", #msgs == 0)
    local e = snapshot_find(url)
    check("命中：占位换键为 comment URL 且台账集为真实标题",
        e ~= nil and e.episode == "第14话 副标题14")
    check("命中：bangumi+comment 恰好各一次",
        #net.calls == 2 and net.calls[1]:find("/api/v2/bangumi/7506", 1, true) ~= nil)
end

-- ---------- 用例 2：越界诚实失败（用户场景：源 25 集、本地第 26 集特别篇） ----------
steps[3] = function()
    source_status.reset()
    wh, msgs, net.calls = {}, {}, {}
    DANMAKU.sources = {}
    DANMAKU.anime, DANMAKU.episode = nil, nil
    net.bangumi = amagami_bangumi_json()
    source_status.begin({
        { key = "extra:ddp", provider = "ddp", anime = "圣诞之吻SS" },
    })
    resume_dandanplay_episode(75060025, 1, SERVER, "第26话", STUB_PATH)
end

steps[4] = function()
    local e = snapshot_find("extra:ddp")
    check("越界：台账 extra:ddp 留痕失败", e ~= nil and e.status == "failed")
    check("越界：失败原因含源集数",
        e ~= nil and e.error ~= nil and e.error:find("该源共25话", 1, true) ~= nil, e and e.error)
    check("越界：不写 history（不落错误 episodeId）", #wh == 0)
    check("越界：不写 DANMAKU.sources", next(DANMAKU.sources) == nil)
    check("越界：触发兜底搜索消息",
        #msgs == 1 and msgs[1]:find("auto_load_fallback", 1, true) ~= nil)
    -- 会话级 bangumi 缓存命中（用例 1 已拉过同番分集表）：零网络即完成校验与诚实失败
    check("越界：缓存命中零网络（零 comment 请求）", #net.calls == 0)
end

-- ---------- 用例 3：bangumi 网络失败 → 回退旧算术（未校验标注） ----------
steps[5] = function()
    source_status.reset()
    wh, msgs, net.calls = {}, {}, {}
    DANMAKU.sources = {}
    DANMAKU.anime, DANMAKU.episode = nil, nil
    net.bangumi = amagami_bangumi_json()
    net.fail_all = false
    -- 用未缓存过的番（bangumiId 7606）：首条 bangumi 请求报错（失败不缓存），
    -- 随后回退算术的 comment 请求正常（包装桩只拦 bangumi 首请求，其余委托原桩）
    local first_bangumi = true
    local real_async = call_cmd_async
    call_cmd_async = function(args, cb)
        local url = args[#args]
        if url:find("/api/v2/bangumi/", 1, true) and first_bangumi then
            first_bangumi = false
            net.calls[#net.calls + 1] = url
            mp.add_timeout(0.01, function() cb("curl: (28) timeout", nil) end)
            return
        end
        real_async(args, cb)
    end
    source_status.begin({
        { key = "extra:ddp", provider = "ddp", anime = "圣诞之吻SS" },
    })
    resume_dandanplay_episode(76060013, 1, SERVER, "第14话", STUB_PATH)
end

steps[6] = function()
    check("回退：write_history 收到旧算术 id", #wh == 1 and wh[1].episodeid == 76060014)
    check("回退：显示标注未校验", wh[1].episode == "第14话（未校验）")
    check("回退：源条目同样标注未校验",
        DANMAKU.sources[SERVER .. "/api/v2/comment/76060014?withRelated=true&chConvert=0"] ~= nil
        and DANMAKU.sources[SERVER .. "/api/v2/comment/76060014?withRelated=true&chConvert=0"]
            .episode_title == "第14话（未校验）")
    check("回退：正常加载不触发兜底搜索", #msgs == 0)
end

-- ---------- 用例 4：迟到回调防护（bangumi 响应到达时已换集） ----------
steps[7] = function()
    source_status.reset()
    wh, msgs, net.calls = {}, {}, {}
    DANMAKU.sources = {}
    DANMAKU.anime, DANMAKU.episode = nil, nil
    net.bangumi = amagami_bangumi_json()
    STUB.path = "E:/Anime/Amagami/[VCB-Studio] Amagami SS 27.mkv"  -- 已换集
    resume_dandanplay_episode(75060013, 1, SERVER, "第14话", STUB_PATH)
end

steps[8] = function()
    check("迟到回调：换集后放弃（零写入零消息）",
        #wh == 0 and #msgs == 0 and next(DANMAKU.sources) == nil)
    STUB.path = nil
end

-- ---------- 用例 5：锚 episodeId 异常（历史记录损坏） ----------
steps[9] = function()
    source_status.reset()
    wh, msgs, net.calls = {}, {}, {}
    DANMAKU.sources = {}
    source_status.begin({
        { key = "extra:ddp", provider = "ddp", anime = "圣诞之吻SS" },
    })
    resume_dandanplay_episode("corrupt-id", 1, SERVER, "第14话", STUB_PATH)
end

steps[10] = function()
    local e = snapshot_find("extra:ddp")
    check("坏锚：台账留痕失败且原因明示",
        e ~= nil and e.status == "failed" and e.error ~= nil
        and e.error:find("非数字", 1, true) ~= nil, e and e.error)
    check("坏锚：不写 history 零网络", #wh == 0 and #net.calls == 0)
end

local function finish()
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
