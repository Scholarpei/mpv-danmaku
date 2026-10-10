-- 弹幕过滤菜单 handler 测试：模拟 uosc 回调事件，验证开关/档位/动作与管线重跑
-- 注意：script-message-to 经 mpv 事件循环异步派发，动作与断言须分步延时执行
-- 运行：mpv.com --no-config --idle=once --script=<本文件>

local ROOT = "D:/software/mpv-lazy/portable_config/scripts/uosc_danmaku"
package.path = ROOT .. "/?.lua;" .. package.path

local utils = require("mp.utils")
local stub = { msgs = {}, rebuilds = 0 }

show_message = function(text, time) stub.msgs[#stub.msgs + 1] = tostring(text) end
load_danmaku = function(from_menu) stub.rebuilds = stub.rebuilds + 1 end
add_source_to_history = function(url, src)
    stub.history_urls = stub.history_urls or {}
    stub.history_urls[#stub.history_urls + 1] = url
end
PLATFORM = "windows"

-- 「屏蔽此文本」用例的临时黑名单文件（绝对路径，不触发 resolve 的目录回退分支）。
-- 不预先创建：保持用例 6 走「黑名单文件不存在」提示路径（避免测试中真的打开 explorer）
local BLACK_TMP = ROOT .. "/tests/black_menu_test.tmp.txt"
os.remove(BLACK_TMP)

require("modules/options")
options.blacklist_path = BLACK_TMP
require("modules/utils")
require("modules/parse")
require("modules/menu")

-- 模拟 uosc 环境（menu.lua 加载时置 false，需在其后覆盖），
-- 走 uosc 刷新分支，避免 mp.input 交互提示干扰 show_message 计数
uosc_available = true

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

local name = mp.get_script_name()
local function activate(key)
    mp.commandv("script-message-to", name, "setup-danmaku-filter",
        utils.format_json({ type = "activate", value = key }))
end

-- 每步之间留出事件派发间隔
local steps = {
    function() activate("merge_enabled") end,
    function()
        check("1 开关切换 merge_enabled 关", options.merge_enabled == false and stub.rebuilds == 1)
        activate("merge_enabled")
    end,
    function()
        check("1b 开关切回 merge_enabled 开", options.merge_enabled == true and stub.rebuilds == 2)
        activate("merge_tolerance")
    end,
    function()
        check("2 档位循环 30->60", tonumber(options.merge_tolerance) == 60 and stub.rebuilds == 3)
        activate("max_screen_danmaku")
    end,
    function()
        check("3 档位循环 0->20", tonumber(options.max_screen_danmaku) == 20 and stub.rebuilds == 4)
        for _ = 1, 5 do activate("max_screen_danmaku") end
    end,
    function()
        check("3b 档位循环回绕", tonumber(options.max_screen_danmaku) == 0)
        options.merge_pinyin = "no"
        activate("merge_pinyin")
    end,
    function()
        check("4 conf 字符串 no 视为关，切换后为开", options.merge_pinyin == true)
        stub.msgs = {}
        activate("reload_blacklist")
    end,
    function()
        check("5 重载黑名单提示与重跑",
            #stub.msgs == 1 and stub.msgs[1]:find("0", 1, true) and stub.rebuilds >= 5)
        stub.msgs = {}
        stub.rebuilds_before = stub.rebuilds
        activate("open_blacklist_location")
    end,
    function()
        check("6 文件不存在提示且不重跑（不打开资源管理器）",
            #stub.msgs == 1 and stub.rebuilds == stub.rebuilds_before
                and stub.msgs[1]:find("不存在", 1, true))
        activate("merge_similarity") -- medium -> strong
    end,
    function()
        check("8 相似度循环 medium->strong", options.merge_similarity == "strong")
        activate("merge_similarity") -- strong -> off
    end,
    function()
        check("8b 相似度循环 strong->off", options.merge_similarity == "off")
        activate("merge_similarity") -- off -> light
    end,
    function()
        check("8c 相似度循环 off->light", options.merge_similarity == "light")
        activate("merge_similarity") -- light -> medium（回绕）
    end,
    function()
        check("8d 相似度循环回绕 light->medium", options.merge_similarity == "medium")
        activate("convert_top_to_scroll") -- false -> true
    end,
    function()
        check("9 转滚动三态 关->全部", options.convert_top_to_scroll == true)
        activate("convert_top_to_scroll") -- true -> auto
    end,
    function()
        check("9b 转滚动三态 全部->自动", options.convert_top_to_scroll == "auto")
        activate("convert_top_to_scroll") -- auto -> false（回绕）
    end,
    function()
        check("9c 转滚动三态 自动->关", options.convert_top_to_scroll == false)
        options.convert_top_to_scroll = "yes" -- conf 字符串写法
        activate("convert_top_to_scroll") -- yes 归一为 true -> auto
    end,
    function()
        check("9d conf yes 归一后循环到 auto", options.convert_top_to_scroll == "auto")
        options.convert_top_to_scroll = false
        options.merge_tolerance = "30" -- conf 字符串态的数值档
        activate("merge_tolerance") -- "30" 须 tonumber 归一后取下一档 60
    end,
    function()
        check("10 conf 字符串数值档位匹配", tonumber(options.merge_tolerance) == 60)
        stub.rebuilds_before = stub.rebuilds
        activate("density_control") -- smart -> off
    end,
    function()
        check("11 密度控制 smart->off",
            options.density_control == "off" and stub.rebuilds == stub.rebuilds_before + 1)
        activate("density_control") -- off -> simple
    end,
    function()
        check("11b 密度控制 off->simple", options.density_control == "simple")
        activate("density_control") -- simple -> smart（回绕）
    end,
    function()
        check("11c 密度控制回绕 simple->smart", options.density_control == "smart")
        activate("density_level") -- medium -> strict
    end,
    function()
        check("12 密度强度 medium->strict", options.density_level == "strict")
        activate("density_level") -- strict -> loose
    end,
    function()
        check("12b 密度强度 strict->loose", options.density_level == "loose")
        activate("density_level") -- loose -> medium（回绕）
    end,
    function()
        check("12c 密度强度回绕 loose->medium", options.density_level == "medium")
        stub.rebuilds_before = stub.rebuilds
        activate("chConvert") -- 默认 1（简体）-> 2
    end,
    function()
        check("13 简繁循环 简体->繁体", tonumber(options.chConvert) == 2)
        activate("chConvert") -- 2 -> 0
    end,
    function()
        check("13b 简繁循环 繁体->关", tonumber(options.chConvert) == 0)
        activate("chConvert") -- 0 -> 1（回绕）
    end,
    function()
        check("13c 简繁循环回绕 关->简体",
            options.chConvert == 1 and stub.rebuilds == stub.rebuilds_before + 3)
        options.chConvert = "1" -- 模拟 conf 字符串态的数值档
        activate("chConvert") -- tonumber 归一 1 -> 2
    end,
    function()
        check("13d conf 字符串数值档位匹配", tonumber(options.chConvert) == 2)
        options.chConvert = 1 -- 还原默认
        open_filter_menu_uosc()
    end,
    function()
        check("7 uosc 菜单构建无异常", true)

        -- ===== 弹幕内容菜单：索引映射 + 屏蔽此文本 =====
        -- 记录派发给 uosc 的 open-menu JSON（包装真 commandv，其余调用透传）
        stub.real_commandv, stub.menu_json = mp.commandv, nil
        mp.commandv = function(...)
            local args = { ... }
            if args[1] == "script-message-to" and args[2] == "uosc" and args[3] == "open-menu" then
                stub.menu_json = args[4]
            end
            return stub.real_commandv(...)
        end
        -- 索引漂移场景：COMMENTS[1] 空文本、[2] 越界时长被滤掉，仅 [3] 进入菜单。
        -- blacklist_key 含 pattern 魔法字符，顺带验证写入时的转义
        COMMENTS = {
            { clean_text = "   ", source = "srcWRONG", start_time = 0, end_time = 1 },
            { clean_text = "第二条", source = "srcB", start_time = 5, end_time = 6 },
            { clean_text = "屏蔽(我)x3", source = "srcA", start_time = 0, end_time = 10,
                merge_count = 3, merged_x_suffix = true, blacklist_key = "屏蔽(我)" },
        }
        DANMAKU = { sources = { srcWRONG = {}, srcB = {}, srcA = {} }, count = 3 }
        open_content_menu(0)
    end,
    function()
        local props = stub.menu_json and utils.parse_json(stub.menu_json)
        check("C1 内容菜单过滤后仅 1 项且含 ×N 提示",
            props ~= nil and #props.items == 1
                and props.items[1].title:find("屏蔽(我)x3", 1, true)
                and props.items[1].hint:find("×3", 1, true))
        mp.commandv("script-message-to", name, "handle-danmaku-content-action",
            utils.format_json({ type = "activate", index = 1, action = "block_source" }))
    end,
    function()
        check("C2 索引映射：动作作用于 COMMENTS[3] 而非被滤掉的 [1]",
            DANMAKU.sources.srcA.blocked == true and DANMAKU.sources.srcWRONG.blocked == nil
                and stub.history_urls[#stub.history_urls] == "srcA")
        stub.msgs = {}
        mp.commandv("script-message-to", name, "handle-danmaku-content-action",
            utils.format_json({ type = "activate", index = 1, action = "block_text" }))
    end,
    function()
        local f = io.open(BLACK_TMP, "r")
        local line = f and f:read("*l")
        if f then f:close() end
        check("C3 屏蔽此文本：转义写入并命中",
            line == "^屏蔽%(我%)$" and is_text_blacklisted("屏蔽(我)")
                and #stub.msgs == 1 and stub.msgs[1]:find("已屏蔽", 1, true))
        stub.msgs = {}
        mp.commandv("script-message-to", name, "handle-danmaku-content-action",
            utils.format_json({ type = "activate", index = 1, action = "block_text" }))
    end,
    function()
        local n = 0
        local f = io.open(BLACK_TMP, "r")
        if f then
            for _ in f:lines() do n = n + 1 end
            f:close()
        end
        check("C4 重复屏蔽提示且不重复写入", #stub.msgs == 1
            and stub.msgs[1]:find("已在黑名单", 1, true) and n == 1)
        os.remove(BLACK_TMP)
        mp.commandv = stub.real_commandv
        print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
        -- os.exit 直杀：mpv 正常 quit 的关机路径在 Windows 控制台代理下偶发挂起（测试环境已知问题）
        os.exit(failures > 0 and 1 or 0)
    end,
}

local i = 0
local function run_step()
    i = i + 1
    if steps[i] then
        steps[i]()
        mp.add_timeout(0.1, run_step)
    end
end
mp.add_timeout(0.1, run_step)
