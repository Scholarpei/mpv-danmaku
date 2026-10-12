-- B站合集文件夹记忆自动加载测试（autoload_bilibili_series 的 exists 分支装载语义与显示标题）：
-- 历史恢复的空壳源（无 data）不再「交给 addon_danmaku」——文件夹有 extras 时 addon_danmaku
-- 整体跳过 sources 重放，委托会标记完成却无人取数（OSD 显示 bilibili 02 但弹幕不加载），
-- 应就地以既有 key 装载；已到货/被屏蔽的源保持零网络；无既有源时走规范化 URL（原行为）；
-- 源显示标题用B站投稿标题（view 接口），非本地文件夹标题
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
    .. "/bili_autoload_test_" .. tostring(os.time()) .. "_"
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
local loads = 0
show_message = function() end
load_danmaku = function(from_menu) loads = loads + 1 end
DANMAKU = { sources = {}, count = 1 }

-- mp 属性桩：本地文件路径恒定（过期回调校验用），标题解析恒为第 2 集
local STUB_PATH = TMP .. "/Show - 02.mkv"
mp.get_property = function(name, default)
    if name == "path" then return STUB_PATH end
    if name == "filename/no-ext" then return "Show - 02" end
    if name == "working-directory" then return "" end
    return default
end
mp.get_property_number = function(name, default)
    if name == "duration" then return 1975 end
    return default
end

require("modules/options")
options.bilibili_series_memory = "add"
require("modules/utils")

-- parse_title / call_cmd_async 须在 require("modules/utils") 之后打桩：
-- utils 加载期定义真身全局，先定义会被覆盖（桩序与 tests/sites_cache_test.lua 一致）
parse_title = function() return "测试番剧", 2, 2 end

local BILI_XML = '<?xml version="1.0" encoding="UTF-8"?><i>'
    .. '<d p="1.000,1,25,16777215,1,0,0,0">hi</d>'
    .. '<d p="2.000,4,25,9830415,1,0,0,0">yo</d></i>'
local VIEW_BY_VID = {}
local net = { comment_calls = 0, view_calls = 0 }

call_cmd_async = function(args, cb)
    local url
    for i = #args, 1, -1 do
        local v = args[i]
        if type(v) == "string" and v:find("^https?://") then url = v break end
    end
    mp.add_timeout(0.01, function()
        if url and url:find("web-interface/view", 1, true) then
            net.view_calls = net.view_calls + 1
            cb(nil, VIEW_BY_VID[url:match("bvid=(%w+)")])
        elseif url and url:find("comment%.bilibili%.com/") then
            net.comment_calls = net.comment_calls + 1
            cb(nil, BILI_XML)
        else
            cb("unexpected url: " .. tostring(url), nil)
        end
    end)
    return function() end
end

-- view 接口响应：投稿标题 + 分P列表（12 页、part 为零填充集数、cid=40000+page）
local BILI_ARCHIVE_TITLE = "B站测试投稿标题"
do
    local parts = {}
    for i = 1, 12 do
        parts[#parts + 1] = ('{"page":%d,"cid":%d,"part":"%02d","duration":1975}')
            :format(i, 40000 + i, i)
    end
    local json = '{"code":0,"data":{"title":"' .. BILI_ARCHIVE_TITLE
        .. '","pages":[' .. table.concat(parts, ",") .. ']}}'
    VIEW_BY_VID["BVAutoAA00"] = json
    VIEW_BY_VID["BVAutoBB00"] = json
end

require("modules/parse")
require("apis/dandanplay")
source_status = require("modules/source_status")
require("sites/bilibili")

local dc = require("modules/danmaku_cache")
dc.setup({
    enabled = true, dir = TMP, ttl_seconds = 3600, max_bytes = 0,
    platform = PLATFORM,
    run_sync = function(cmd) return mp.command_native(cmd) end,
    log = function() end,
})

HISTORY_PATH = TMP .. "/history.json"

local RAW_URL = "https://www.bilibili.com/video/BVAutoAA00?p=2"
local CANON_URL = "https://www.bilibili.com/video/BVAutoAA00/?p=2"
local DIR_KEY = get_parent_directory(STUB_PATH)
local RECORDS = { BVAutoAA00 = { page = 2, episode = 2, ts = os.time() } }

local steps = {}

-- ---------- 用例组 A（回归主线）：历史恢复的空壳源 → 就地装载 ----------
steps[1] = function()
    DANMAKU = { sources = {}, count = 1 }
    DANMAKU.sources[RAW_URL] = {
        from = "user_custom", provider = "bilibili",
        blocked = false, from_history = true,
    }
    source_status.reset()
    source_status.begin({})
    loads = 0
    net.comment_calls = 0
    net.view_calls = 0
    steps._fallback_runs = 0
    autoload_bilibili_series(STUB_PATH, DIR_KEY, RECORDS, function()
        steps._fallback_runs = steps._fallback_runs + 1
    end)
end

steps[2] = function()
    local src = DANMAKU.sources[RAW_URL]
    check("A 空壳源就地装载（data 入既有 key）",
        src ~= nil and src.data ~= nil and #src.data == 2)
    check("A 不新增规范化重复源", DANMAKU.sources[CANON_URL] == nil)
    check("A 保留既有 from/provider", src and src.from == "user_custom"
        and src.provider == "bilibili")
    check("A 显示标题用B站投稿标题", src and src.anime_title == BILI_ARCHIVE_TITLE)
    check("A 补分P标题锚点", src and src.episode_title == "02")
    check("A 走 load_danmaku 渲染", loads >= 1)
    check("A 弹幕 XML 恰好取一次", net.comment_calls == 1)
    check("A view 接口恰好取一次（autoload 与取数共享缓存）", net.view_calls == 1)
    check("A add 模式先跑 fallback（弹弹play流程）", steps._fallback_runs == 1)
    local lines = table.concat(source_status.format_lines(), " | ")
    check("A 状态汇总完成且带条数",
        lines:find("bilibili", 1, true) ~= nil and lines:find("2条", 1, true) ~= nil
            and lines:find("等待中", 1, true) == nil)
    check("A 汇总显示B站投稿标题而非本地标题",
        lines:find(BILI_ARCHIVE_TITLE, 1, true) ~= nil
            and lines:find("测试番剧", 1, true) == nil)
end

-- ---------- 用例组 B（原委托语义保留）：已到货的源零网络 ----------
steps[3] = function()
    DANMAKU = { sources = {}, count = 1 }
    DANMAKU.sources[RAW_URL] = {
        from = "user_custom", provider = "bilibili", from_history = true,
        data = { { time = 1 }, { time = 2 }, { time = 3 } },
    }
    source_status.reset()
    source_status.begin({})
    loads = 0
    net.comment_calls = 0
    net.view_calls = 0
    autoload_bilibili_series(STUB_PATH, DIR_KEY, RECORDS, function() end)
end

steps[4] = function()
    check("B 已到货不再取数", net.comment_calls == 0)
    check("B 已到货不重渲染", loads == 0)
    check("B view 会话缓存零网络", net.view_calls == 0)
    local lines = table.concat(source_status.format_lines(), " | ")
    check("B 完成条数按既有 data 解析（3条）", lines:find("3条", 1, true) ~= nil)
    check("B 汇总显示B站投稿标题",
        lines:find(BILI_ARCHIVE_TITLE, 1, true) ~= nil)
end

-- ---------- 用例组 C：被屏蔽的源零网络 ----------
steps[5] = function()
    DANMAKU = { sources = {}, count = 1 }
    DANMAKU.sources[RAW_URL] = {
        from = "user_custom", provider = "bilibili",
        blocked = true, from_history = true,
    }
    source_status.reset()
    source_status.begin({})
    net.comment_calls = 0
    net.view_calls = 0
    autoload_bilibili_series(STUB_PATH, DIR_KEY, RECORDS, function() end)
end

steps[6] = function()
    check("C 被屏蔽不取数", net.comment_calls == 0)
    check("C 被屏蔽不写 data", DANMAKU.sources[RAW_URL].data == nil)
end

-- ---------- 用例组 D（原行为回归守护）：无既有源 → 规范化 URL 装载 ----------
steps[7] = function()
    DANMAKU = { sources = {}, count = 1 }
    dc.clear()
    source_status.reset()
    source_status.begin({})
    loads = 0
    net.comment_calls = 0
    net.view_calls = 0
    autoload_bilibili_series(STUB_PATH, DIR_KEY,
        { BVAutoBB00 = { page = 2, episode = 2, ts = os.time() } }, function() end)
end

steps[8] = function()
    local src = DANMAKU.sources["https://www.bilibili.com/video/BVAutoBB00/?p=2"]
    check("D 无既有源建规范化 key 并装载",
        src ~= nil and src.data ~= nil and #src.data == 2)
    check("D 显示标题用B站投稿标题",
        src and src.anime_title == BILI_ARCHIVE_TITLE)
    check("D 走 load_danmaku 渲染", loads >= 1)
    check("D 弹幕 XML 恰好取一次", net.comment_calls == 1)
    check("D view 接口恰好取一次", net.view_calls == 1)
end

-- ---------- 用例组 E：手动粘贴即时盖标题（maybe_record_bilibili_series） ----------
steps[9] = function()
    DANMAKU = { sources = {}, count = 1 }
    DANMAKU.sources[RAW_URL] = {
        from = "user_custom", provider = "bilibili", from_menu = true,
    }
    net.view_calls = 0
    maybe_record_bilibili_series(RAW_URL)
end

steps[10] = function()
    local src = DANMAKU.sources[RAW_URL]
    check("E 粘贴即时盖投稿标题", src and src.anime_title == BILI_ARCHIVE_TITLE)
    check("E 粘贴即时盖分P标题（显式 ?p=2 → 02）", src and src.episode_title == "02")
    local h = utils.parse_json(read_file(HISTORY_PATH) or "") or {}
    local rec = h[DIR_KEY] and h[DIR_KEY].bilibili and h[DIR_KEY].bilibili["BVAutoAA00"]
    check("E 文件夹记忆已写入（锚 page=2）", rec ~= nil and rec.page == 2)
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
