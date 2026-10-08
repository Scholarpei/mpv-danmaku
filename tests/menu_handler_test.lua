-- 弹幕过滤菜单 handler 测试：模拟 uosc 回调事件，验证开关/档位/动作与管线重跑
-- 注意：script-message-to 经 mpv 事件循环异步派发，动作与断言须分步延时执行
-- 运行：mpv.com --no-config --idle=once --script=<本文件>

local ROOT = "D:/software/mpv-lazy/portable_config/scripts/uosc_danmaku"
package.path = ROOT .. "/?.lua;" .. package.path

local utils = require("mp.utils")
local stub = { msgs = {}, rebuilds = 0 }

show_message = function(text, time) stub.msgs[#stub.msgs + 1] = tostring(text) end
load_danmaku = function(from_menu) stub.rebuilds = stub.rebuilds + 1 end
PLATFORM = "windows"

require("modules/options")
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
        check("6 未配置路径提示且不重跑",
            #stub.msgs == 1 and stub.rebuilds == stub.rebuilds_before
                and stub.msgs[1]:find("blacklist_path", 1, true))
        open_filter_menu_uosc()
    end,
    function()
        check("7 uosc 菜单构建无异常", true)
        print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
        mp.commandv("quit")
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
