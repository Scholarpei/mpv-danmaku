-- 站点 add-XX-event 多选改造回归测试（tencent + maccms + acfun + ezdmw + girigirilove +
-- aiyifan 六站 + ezdmw 多季复合集数键）：
-- 添加集数后不再向 uosc 发 close-menu（菜单保持打开）、add_danmaku_source 被
-- 以预期参数调用（tencent/acfun）、同源换选驱逐旧集源（数据层单选收紧）+ 旧标记
-- 清除新标记高亮（标记层 exclusive）、update-menu 原地刷新、
-- ezdmw 多季番第二季以 season*10000+ep 复合键换选（显示名 第2季13集）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local utils = require("mp.utils")

-- ---- 打桩（require 前置；模块运行时按全局查找这些名字）----
local stub = { msgs = {}, sources = {} }
show_message = function(text, time) stub.msgs[#stub.msgs + 1] = tostring(text) end
load_danmaku = function() end
add_source_to_history = function() end
write_history = function() end
-- 半真桩：记录调用参数并模拟真实登记（写 DANMAKU.sources，供驱逐断言）
add_danmaku_source = function(query, from_menu, provider, meta)
    stub.sources[#stub.sources + 1] =
        { query = query, from_menu = from_menu, provider = provider }
    DANMAKU.sources[query] = { from = "user_custom", provider = provider }
end
PLATFORM = "windows"
DANMAKU = { sources = {}, count = 1 }

require("modules/options")
require("modules/utils")
require("modules/parse")
require("modules/menu")
require("apis/tencent_search")
require("apis/maccms")
require("apis/acfun_search")
require("apis/ezdmw_search")
require("apis/ggl_search")
require("apis/aiyifan_search")

-- 模拟 uosc 环境（menu.lua 加载时检测为 false，需在其后覆盖）
uosc_available = true

-- 捕获发往 uosc 的菜单命令（重点盯 close-menu）
local sent = {}
local real_commandv = mp.commandv
mp.commandv = function(...)
    local args = { ... }
    if args[1] == "script-message-to" and args[2] == "uosc"
        and (args[3] == "open-menu" or args[3] == "update-menu" or args[3] == "close-menu") then
        sent[#sent + 1] = { cmd = args[3], json = args[4] }
    end
    return real_commandv(...)
end
local function close_menu_count()
    local n = 0
    for _, s in ipairs(sent) do
        if s.cmd == "close-menu" then n = n + 1 end
    end
    return n
end

mp.set_property_native("user-data/uosc/menu/type", "menu_details")

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

local steps = {
    function()
        -- ===== tencent：add-tx-event 不关菜单 + 记参 + 同源换选驱逐 =====
        local items = {
            { title = "↩️ 返回搜索结果",
                value = { "script-message-to", "uosc", "open-menu", "{}" },
                keep_open = false, selectable = true },
            { title = "第1集",
                value = { "script-message-to", name, "add-tx-event",
                    "cid1", "vid1", "1", "T", "2024", "动漫" },
                keep_open = true },
            { title = "第2集", hint = "标题甲",
                value = { "script-message-to", name, "add-tx-event",
                    "cid1", "vid2", "2", "T", "2024", "动漫" },
                keep_open = true },
        }
        -- 生产行为：各站渲染处均以 exclusive=true 记快照（同源单选）
        remember_details_menu("menu_details", "T (2024)", items, "使用 / 打开筛选", true)
        mp.commandv("script-message-to", name, "add-tx-event",
            "cid1", "vid1", "1", "T", "2024", "动漫")
    end,
    function()
        -- 换选第2集：应驱逐第1集源（数据层）+ 清第1集标记（标记层）
        mp.commandv("script-message-to", name, "add-tx-event",
            "cid1", "vid2", "2", "T", "2024", "动漫")
    end,
    function()
        local st = current_details_menu
        check("1 tencent 两次添加均不发 close-menu", close_menu_count() == 0)
        check("1b add_danmaku_source 以预期 URL/provider 被调两次",
            #stub.sources == 2
                and stub.sources[1].query == "https://v.qq.com/x/cover/cid1/vid1.html"
                and stub.sources[2].query == "https://v.qq.com/x/cover/cid1/vid2.html"
                and stub.sources[2].from_menu == true and stub.sources[2].provider == "腾讯视频")
        check("1c 数据层单选收紧：同源旧集源被驱逐、只留新选",
            DANMAKU.sources["https://v.qq.com/x/cover/cid1/vid1.html"] == nil
                and DANMAKU.sources["https://v.qq.com/x/cover/cid1/vid2.html"] ~= nil)
        check("1d 标记层 exclusive：旧集标记清除（active+hint 还原）、新集高亮",
            st.items[2].active == nil and st.items[2].hint == nil
                and st.items[3].active == true and st.items[3].hint == "标题甲 | 已添加")
        check("1e footnote 计数为 1",
            st.footnote:find("已添加 1 个源", 1, true) ~= nil)
        check("1f 原地刷新走 update-menu",
            sent[#sent] ~= nil and sent[#sent].cmd == "update-menu")

        -- ===== maccms：cached_vod miss 走提示路径，mark 仍刷新不关菜单 =====
        local m_items = {
            { title = "↩️ 返回搜索结果",
                value = { "script-message-to", "uosc", "open-menu", "{}" },
                keep_open = false, selectable = true },
            { title = "第1集",
                value = { "script-message-to", name, "add-maccms-event",
                    "srv", "vod1", "1", "1" },
                keep_open = true },
            { title = "第2集",
                value = { "script-message-to", name, "add-maccms-event",
                    "srv", "vod1", "1", "2" },
                keep_open = true },
        }
        remember_details_menu("menu_details", "采集剧 (2024)", m_items, "使用 / 打开筛选", true)
        mp.commandv("script-message-to", name, "add-maccms-event", "srv", "vod1", "1", "2")
    end,
    function()
        check("2 maccms 添加后不发 close-menu", close_menu_count() == 0)
        check("2b load 路径可达（cached_vod miss 走缺失提示）",
            #stub.msgs == 1 and stub.msgs[1]:find("剧集信息缺失", 1, true) ~= nil)
        check("2c 点击集打标（mark 不依赖 load 成败）",
            current_details_menu.items[3].active == true)
        check("2d 原地刷新走 update-menu", sent[#sent] ~= nil and sent[#sent].cmd == "update-menu")

        -- ===== acfun：专辑分P换选（每P独立 ac号，规范 URL 带 part=1）=====
        local a_items = {
            { title = "↩️ 返回搜索结果",
                value = { "script-message-to", "uosc", "open-menu", "{}" },
                keep_open = false, selectable = true },
            { title = "第1话",
                value = { "script-message-to", name, "add-acf-event",
                    "39477926", "1", "1", "孤独摇滚！", "op", "6115094" },
                keep_open = true },
            { title = "第2话", hint = "ED1",
                value = { "script-message-to", name, "add-acf-event",
                    "39477956", "1", "2", "孤独摇滚！", "ED1", "6115094" },
                keep_open = true },
        }
        remember_details_menu("menu_details", "孤独摇滚！", a_items, "使用 / 打开筛选", true)
        mp.commandv("script-message-to", name, "add-acf-event",
            "39477926", "1", "1", "孤独摇滚！", "op", "6115094")
    end,
    function()
        mp.commandv("script-message-to", name, "add-acf-event",
            "39477956", "1", "2", "孤独摇滚！", "ED1", "6115094")
    end,
    function()
        local st = current_details_menu
        check("3 acfun 两次添加均不发 close-menu", close_menu_count() == 0)
        check("3b add_danmaku_source 以预期 URL/provider 被调两次",
            #stub.sources == 4
                and stub.sources[3].query == "https://www.acfun.cn/v/ac39477926?part=1"
                and stub.sources[4].query == "https://www.acfun.cn/v/ac39477956?part=1"
                and stub.sources[4].from_menu == true and stub.sources[4].provider == "AcFun")
        check("3c 数据层单选收紧：同源旧集源被驱逐、只留新选",
            DANMAKU.sources["https://www.acfun.cn/v/ac39477926?part=1"] == nil
                and DANMAKU.sources["https://www.acfun.cn/v/ac39477956?part=1"] ~= nil)
        check("3d 标记层 exclusive：旧集标记清除、新集高亮",
            st.items[2].active == nil and st.items[2].hint == nil
                and st.items[3].active == true and st.items[3].hint == "ED1 | 已添加")
        check("3e 原地刷新走 update-menu", sent[#sent] ~= nil and sent[#sent].cmd == "update-menu")

        -- ===== ezdmw：番剧集数换选（每集独立 videoId，规范 URL 直达播放页）=====
        local z_items = {
            { title = "↩️ 返回搜索结果",
                value = { "script-message-to", "uosc", "open-menu", "{}" },
                keep_open = false, selectable = true },
            { title = "第18集",
                value = { "script-message-to", name, "add-ezd-event",
                    "98626", "102508", "18", "Re：从零开始的异世界生活第四季" },
                keep_open = true },
            { title = "第19集",
                value = { "script-message-to", name, "add-ezd-event",
                    "98626", "102578", "19", "Re：从零开始的异世界生活第四季" },
                keep_open = true },
        }
        remember_details_menu("menu_details", "Re：从零开始的异世界生活第四季", z_items, "使用 / 打开筛选", true)
        mp.commandv("script-message-to", name, "add-ezd-event",
            "98626", "102508", "18", "Re：从零开始的异世界生活第四季")
    end,
    function()
        mp.commandv("script-message-to", name, "add-ezd-event",
            "98626", "102578", "19", "Re：从零开始的异世界生活第四季")
    end,
    function()
        local st = current_details_menu
        check("4 ezdmw 两次添加均不发 close-menu", close_menu_count() == 0)
        check("4b add_danmaku_source 以预期 URL/provider 被调两次",
            #stub.sources == 6
                and stub.sources[5].query == "https://www.ezdmw.org/Index/video/102508.html"
                and stub.sources[6].query == "https://www.ezdmw.org/Index/video/102578.html"
                and stub.sources[6].from_menu == true and stub.sources[6].provider == "ezdmw")
        check("4c 数据层单选收紧：同源旧集源被驱逐、只留新选",
            DANMAKU.sources["https://www.ezdmw.org/Index/video/102508.html"] == nil
                and DANMAKU.sources["https://www.ezdmw.org/Index/video/102578.html"] ~= nil)
        check("4d 标记层 exclusive：无 hint 条目打标为纯「已添加」、旧集还原",
            st.items[2].active == nil and st.items[2].hint == nil
                and st.items[3].active == true and st.items[3].hint == "已添加")
        check("4e 原地刷新走 update-menu", sent[#sent] ~= nil and sent[#sent].cmd == "update-menu")

        -- ===== girigirilove：番剧集数换选（规范 URL 直达播放页，带 线路src-集ep）=====
        local g_items = {
            { title = "↩️ 返回搜索结果",
                value = { "script-message-to", "uosc", "open-menu", "{}" },
                keep_open = false, selectable = true },
            { title = "先行01",
                value = { "script-message-to", name, "add-ggl-event",
                    "26868", "1", "1", "JOJO的奇妙冒险 飙马野郎" },
                keep_open = true },
            { title = "第02集",
                value = { "script-message-to", name, "add-ggl-event",
                    "26868", "1", "2", "JOJO的奇妙冒险 飙马野郎" },
                keep_open = true },
        }
        remember_details_menu("menu_details", "JOJO的奇妙冒险 飙马野郎", g_items, "使用 / 打开筛选", true)
        mp.commandv("script-message-to", name, "add-ggl-event",
            "26868", "1", "1", "JOJO的奇妙冒险 飙马野郎")
    end,
    function()
        mp.commandv("script-message-to", name, "add-ggl-event",
            "26868", "1", "2", "JOJO的奇妙冒险 飙马野郎")
    end,
    function()
        local st = current_details_menu
        check("5 girigirilove 两次添加均不发 close-menu", close_menu_count() == 0)
        check("5b add_danmaku_source 以预期 URL/provider 被调两次",
            #stub.sources == 8
                and stub.sources[7].query == "https://ani.girigirilove.com/playGV26868-1-1/"
                and stub.sources[8].query == "https://ani.girigirilove.com/playGV26868-1-2/"
                and stub.sources[8].from_menu == true and stub.sources[8].provider == "girigirilove")
        check("5c 数据层单选收紧：同源旧集源被驱逐、只留新选",
            DANMAKU.sources["https://ani.girigirilove.com/playGV26868-1-1/"] == nil
                and DANMAKU.sources["https://ani.girigirilove.com/playGV26868-1-2/"] ~= nil)
        check("5d 标记层 exclusive：无 hint 条目打标为纯「已添加」、旧集还原",
            st.items[2].active == nil and st.items[2].hint == nil
                and st.items[3].active == true and st.items[3].hint == "已添加")
        check("5e 原地刷新走 update-menu", sent[#sent] ~= nil and sent[#sent].cmd == "update-menu")

        -- ===== aiyifan：番剧集数换选（规范 URL 直达播放页，带 id/videoId/videoType 三参）=====
        local y_items = {
            { title = "↩️ 返回搜索结果",
                value = { "script-message-to", "uosc", "open-menu", "{}" },
                keep_open = false, selectable = true },
            { title = "第1集",
                value = { "script-message-to", name, "add-ayf-event",
                    "aIEHicrw641", "OUOLuGAsKu5", "912438", "1", "1", "葬送的芙莉莲", "01" },
                keep_open = true },
            { title = "第2集",
                value = { "script-message-to", name, "add-ayf-event",
                    "aIEHicrw641", "vFOwdFUykNM", "912441", "1", "2", "葬送的芙莉莲", "02" },
                keep_open = true },
        }
        remember_details_menu("menu_details", "葬送的芙莉莲", y_items, "使用 / 打开筛选", true)
        mp.commandv("script-message-to", name, "add-ayf-event",
            "aIEHicrw641", "OUOLuGAsKu5", "912438", "1", "1", "葬送的芙莉莲", "01")
    end,
    function()
        mp.commandv("script-message-to", name, "add-ayf-event",
            "aIEHicrw641", "vFOwdFUykNM", "912441", "1", "2", "葬送的芙莉莲", "02")
    end,
    function()
        local st = current_details_menu
        check("6 aiyifan 两次添加均不发 close-menu", close_menu_count() == 0)
        check("6b add_danmaku_source 以预期 URL/provider 被调两次",
            #stub.sources == 10
                and stub.sources[9].query == "https://www.yfsp.tv/play/aIEHicrw641?id=OUOLuGAsKu5&videoId=912438&videoType=1"
                and stub.sources[10].query == "https://www.yfsp.tv/play/aIEHicrw641?id=vFOwdFUykNM&videoId=912441&videoType=1"
                and stub.sources[10].from_menu == true and stub.sources[10].provider == "爱壹帆")
        check("6c 数据层单选收紧：同源旧集源被驱逐、只留新选",
            DANMAKU.sources["https://www.yfsp.tv/play/aIEHicrw641?id=OUOLuGAsKu5&videoId=912438&videoType=1"] == nil
                and DANMAKU.sources["https://www.yfsp.tv/play/aIEHicrw641?id=vFOwdFUykNM&videoId=912441&videoType=1"] ~= nil)
        check("6d 标记层 exclusive：无 hint 条目打标为纯「已添加」、旧集还原",
            st.items[2].active == nil and st.items[2].hint == nil
                and st.items[3].active == true and st.items[3].hint == "已添加")
        check("6e 原地刷新走 update-menu", sent[#sent] ~= nil and sent[#sent].cmd == "update-menu")

        -- ===== ezdmw 多季：第二季换选（span「2-13」→ 复合集数键 20013，标题 第2季13集）=====
        local z2_items = {
            { title = "↩️ 返回搜索结果",
                value = { "script-message-to", "uosc", "open-menu", "{}" },
                keep_open = false, selectable = true },
            { title = "第26集",
                value = { "script-message-to", name, "add-ezd-event",
                    "32869", "32894", "26", "圣诞之吻SS" },
                keep_open = true },
            { title = "第2季13集",
                value = { "script-message-to", name, "add-ezd-event",
                    "32869", "51170", "20013", "圣诞之吻SS" },
                keep_open = true },
        }
        remember_details_menu("menu_details", "圣诞之吻SS", z2_items, "使用 / 打开筛选", true)
        mp.commandv("script-message-to", name, "add-ezd-event",
            "32869", "51170", "20013", "圣诞之吻SS")
    end,
    function()
        local st = current_details_menu
        check("7 ezdmw 多季添加不发 close-menu", close_menu_count() == 0)
        check("7b 第二季以复合键正确落源",
            #stub.sources == 11
                and stub.sources[11].query == "https://www.ezdmw.org/Index/video/51170.html"
                and stub.sources[11].from_menu == true and stub.sources[11].provider == "ezdmw")
        check("7c 集显示名派生为 第2季13集", DANMAKU.episode == "第2季13集",
            tostring(DANMAKU.episode))
        check("7d 复合集数键入 extra（续载/预取按此定位）",
            DANMAKU.extra ~= nil and DANMAKU.extra.episodenum == 20013
                and DANMAKU.extra.bangumi_id == "32869")
        check("7e 标记层高亮与原地刷新",
            st.items[3].active == true and sent[#sent] ~= nil
                and sent[#sent].cmd == "update-menu")

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
