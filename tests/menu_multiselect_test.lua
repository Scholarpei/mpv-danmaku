-- 选集菜单多选 helper 测试：remember/mark 打标、幂等、计数 footnote、注册表
-- 恢复、exclusive 单选互斥、未命中静默、dandanplay load-danmaku 全链路（打标 +
-- latest_menu_anime 重嵌）、reset_details_session 换集清空、
-- remove_same_provider_sources 数据层驱逐（同源单选收紧）。
-- 生产各站选集菜单均为 exclusive 单选（换选即替换）；用例 1-4 以非 exclusive
-- 菜单形状验证 helper 双模式机制（exclusive 关闭时多标语义仍可用）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local utils = require("mp.utils")

-- ---- 打桩（require 前置；模块运行时按全局查找这些名字）----
show_message = function() end
load_danmaku = function() end
add_source_to_history = function() end
set_danmaku_button = function() end
set_episode_id = function(input, from_menu, api_server, meta)
    _G.stub_set_episode_id = { input = input, from_menu = from_menu, api_server = api_server,
        meta = meta }
end
PLATFORM = "windows"
DANMAKU = { sources = {}, count = 1 }

require("modules/options")
require("modules/utils")
require("modules/parse")
require("modules/menu")

-- 模拟 uosc 环境（menu.lua 加载时检测为 false，需在其后覆盖）
uosc_available = true

-- 捕获发往 uosc 的 open-menu/update-menu/close-menu
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

-- 模拟「选集菜单正开着」→ update_menu_uosc 走 update-menu 分支
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
local function tx_value(vid, epno)
    return { "script-message-to", name, "add-tx-event", "cid1", vid, epno, "T", "2024", "动漫" }
end

local function mk_items()
    return {
        { title = "↩️ 返回搜索结果",
            value = { "script-message-to", "uosc", "open-menu", "{}" },
            keep_open = false, selectable = true },
        { title = "第1集", value = tx_value("vid1", "1") },
        { title = "第2集", hint = "标题甲", value = tx_value("vid2", "2") },
        { title = "第3集", value = tx_value("vid3", "3") },
    }
end

-- ===== 用例 1：mark 命中打标 + update-menu 刷新 + footnote 计数 =====
do
    local items = mk_items()
    remember_details_menu("menu_details", "T (2024)", items, "使用 / 打开筛选")
    local sent_before = #sent
    local hit = mark_details_episode_added(tx_value("vid2", "2"))
    check("1 mark 命中返回 true", hit == true)
    check("1b active 高亮 + hint 追加",
        items[3].active == true and items[3].hint == "标题甲 | 已添加")
    check("1c 其它集未被波及",
        items[2].active == nil and items[4].active == nil)
    check("1d footnote 计数",
        current_details_menu.footnote:find("已添加 1 个源", 1, true) ~= nil
            and current_details_menu.footnote:find("使用 / 打开筛选", 1, true) ~= nil)
    check("1e 刷新走 update-menu（菜单开着）",
        #sent == sent_before + 1 and sent[#sent].cmd == "update-menu")

    -- ===== 用例 2：重复 mark 幂等 =====
    mark_details_episode_added(tx_value("vid2", "2"))
    check("2 重复 mark 幂等（hint 不堆叠）",
        items[3].hint == "标题甲 | 已添加" and #added_details_values == 1)

    -- ===== 用例 3：多集多标 + 计数增长 =====
    mark_details_episode_added(tx_value("vid1", "1"))
    check("3 双 active + 计数 2",
        items[2].active == true and items[3].active == true
            and current_details_menu.footnote:find("已添加 2 个源", 1, true) ~= nil)

    -- ===== 用例 4：重进菜单按注册表恢复历史标记 =====
    local fresh = mk_items()
    remember_details_menu("menu_details", "T (2024)", fresh, "使用 / 打开筛选")
    check("4 重进恢复历史标记",
        fresh[2].active == true and fresh[3].active == true
            and fresh[2].hint == "已添加" and fresh[3].hint == "标题甲 | 已添加")
end

-- ===== 用例 5：exclusive 单选互斥（menu_episodes 语义）=====
do
    local items = mk_items()
    remember_details_menu("menu_episodes", "剧集信息", items, "file.mp4", true,
        { bangumiId = "bg1", api_server = "https://api" })
    mark_details_episode_added(tx_value("vid1", "1"))
    mark_details_episode_added(tx_value("vid3", "3"))
    check("5 exclusive 旧选清除（active+hint 还原）",
        items[2].active == nil and items[2].hint == nil)
    check("5b exclusive 新选唯一高亮",
        items[4].active == true and current_details_menu.footnote:find("已添加 1 个源", 1, true) ~= nil)
    local ep_count = 0
    for _, e in ipairs(added_details_values) do
        if e.menu_type == "menu_episodes" then ep_count = ep_count + 1 end
    end
    check("5c 注册表按 menu_type 过滤清理",
        ep_count == 1 and #added_details_values == 3) -- menu_details 2 + menu_episodes 1
end

-- ===== 用例 6：mark 未命中静默 =====
do
    local sent_before = #sent
    local hit = mark_details_episode_added({ "script-message-to", name, "add-tx-event",
        "other", "vidX", "9", "T", "2024", "动漫" })
    check("6 未命中返回 false 且无刷新", hit == false and #sent == sent_before)
end

-- ===== 用例 7：dandanplay load-danmaku 全链路（消息驱动，异步步进）=====
local steps
steps = {
    function()
        -- 预置 latest_menu_anime：含 dandanplay 条目（value[5]=bangumiId, value[6]=api_server）
        latest_menu_anime = utils.format_json({
            type = "menu_anime", title = "搜索",
            items = {
                { title = "其它源条目", value = { "script-message-to", name, "get-x-event", "x" } },
                { title = "弹弹play 番剧X", hint = "2024 | dandanplay",
                    value = { "script-message-to", name, "search-episodes-event",
                        "番剧X", "bg1", "https://api" } },
            },
        })
        local dd_value = function(ep_title, ep_id)
            return { "script-message-to", name, "load-danmaku",
                "番剧X", ep_title, ep_id, "https://api" }
        end
        local items = {
            { title = "↩️ 返回搜索结果",
                value = { "script-message-to", name, "open-latest-menu-anime", "" },
                keep_open = false, selectable = true },
            { title = "第1话", value = dd_value("第1话", "1001") },
            { title = "第2话", value = dd_value("第2话", "1002") },
        }
        remember_details_menu("menu_episodes", "剧集信息", items, "file.mp4", true,
            { bangumiId = "bg1", api_server = "https://api" })
        -- 先选第1话，再换第2话（exclusive 应清第1话标记）
        mp.commandv("script-message-to", name, "load-danmaku", "番剧X", "第1话", "1001", "https://api")
    end,
    function()
        check("7 set_episode_id 被调（真实加载路径走通）",
            _G.stub_set_episode_id ~= nil and _G.stub_set_episode_id.input == "1001")
        -- 手动菜单补传 meta：源条目/台账拿到真实标题（此前只能显示 URL 截断）
        check("7a set_episode_id 收到标题 meta",
            _G.stub_set_episode_id ~= nil and _G.stub_set_episode_id.meta ~= nil
            and _G.stub_set_episode_id.meta.anime == "番剧X"
            and _G.stub_set_episode_id.meta.episode == "第1话")
        mp.commandv("script-message-to", name, "load-danmaku", "番剧X", "第2话", "1002", "https://api")
    end,
    function()
        local st = current_details_menu
        check("7b exclusive 换选：第1话清除、第2话高亮",
            st.items[2].active == nil and st.items[3].active == true)
        -- 重嵌验证：latest_menu_anime 的嵌套子菜单同步 active（快照字符串已更新）
        local menu_table = utils.parse_json(latest_menu_anime)
        local nested = menu_table and menu_table.items[2] and menu_table.items[2].items
        check("7c latest_menu_anime 重嵌（嵌套子菜单同步高亮）",
            nested ~= nil and #nested == 2
                and nested[1].active == nil and nested[2].active == true)
        check("7d 嵌套条目不混入返回行", nested[1].title == "第1话")

        -- ===== 用例 8：reset_details_session 换集清空 =====
        reset_details_session()
        check("8b reset 清空快照与注册表",
            current_details_menu == nil and #added_details_values == 0)
        local fresh = mk_items()
        remember_details_menu("menu_details", "T (2024)", fresh, "使用 / 打开筛选")
        check("8 reset 后重进不恢复过期标记",
            fresh[2].active == nil and fresh[3].active == nil)

        -- ===== 用例 9：remove_same_provider_sources 数据层驱逐（同源单选收紧）=====
        DANMAKU = { sources = {
            ["https://v.qq.com/x/cover/c/old.html"] = { from = "user_custom", provider = "腾讯视频" },
            ["https://v.qq.com/x/cover/c/new.html"] = { from = "user_custom", provider = "腾讯视频" },
            ["https://api.animeko.org/episode/1"] = { from = "user_custom", provider = "animeko" },
        }, count = 3 }
        local removed = remove_same_provider_sources("腾讯视频", "https://v.qq.com/x/cover/c/new.html")
        check("9 驱逐同 provider 旧源、保留新选与异源",
            removed == true
                and DANMAKU.sources["https://v.qq.com/x/cover/c/old.html"] == nil
                and DANMAKU.sources["https://v.qq.com/x/cover/c/new.html"] ~= nil
                and DANMAKU.sources["https://api.animeko.org/episode/1"] ~= nil)
        check("9b 无可驱逐返回 false",
            remove_same_provider_sources("腾讯视频", "https://v.qq.com/x/cover/c/new.html") == false)
        check("9c provider 为 nil 不动作",
            remove_same_provider_sources(nil, "x") == false)

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
