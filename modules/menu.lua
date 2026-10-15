local msg = require('mp.msg')
local utils = require("mp.utils")
local source_duration = require("modules/source_duration")
local timeline = require("modules/timeline")
require("modules/timeline_menu")
local unpack = unpack or table.unpack

input_loaded, input = pcall(require, "mp.input")
uosc_available = false
latest_menu_anime = {}
local active_request_cancel = nil
local active_request_type = nil
local request_cancelled = false

-- 如果 latest_menu_anime 中存在首项为加载占位，移除它（兼容完整 menu props 或 items 数组）
local function strip_loading_from_latest_menu_anime()
    if not latest_menu_anime or #latest_menu_anime == 0 then return end
    local parsed = utils.parse_json(latest_menu_anime)
    if not parsed or type(parsed) ~= "table" then return end
    local function is_loading_item(it)
        if not it or type(it) ~= "table" then return false end
        if it.title == "加载数据中..." then return true end
        if it.italic == true and it.icon == "spinner" then return true end
        return false
    end
    if parsed.items and type(parsed.items) == "table" then
        if #parsed.items > 0 and is_loading_item(parsed.items[1]) then
            table.remove(parsed.items, 1)
            latest_menu_anime = utils.format_json(parsed)
        end
    else
        if #parsed > 0 and is_loading_item(parsed[1]) then
            table.remove(parsed, 1)
            latest_menu_anime = utils.format_json(parsed)
        end
    end
end

-- 统一取消并发请求：设置取消标志、剥离加载占位并调用实际取消函数
local function perform_cancel_active_request(expected_type)
    if expected_type and active_request_type and tostring(expected_type) ~= tostring(active_request_type) then
        return
    end
    if active_request_cancel then
        request_cancelled = true
        strip_loading_from_latest_menu_anime()
        pcall(active_request_cancel)
        active_request_cancel = nil
        active_request_type = nil
    end
end

-- 供聚合搜索 hub（modules/search_hub.lua）注册/清理当前请求的取消函数
-- （active_request_* 为本文件局部变量，hub 无法直接赋值）
function set_active_request(cancel_fn, menu_type)
    active_request_cancel = cancel_fn
    active_request_type = menu_type
    request_cancelled = false
end

-- dandanplay 搜索结果条目（聚合搜索 hub 与剧集菜单共用同一形状；
-- 旧 get_animes 扇出已删除，纯关键词搜索统一走 modules/search_hub.lua）
function build_dandanplay_menu_item(anime, server, note)
    local hint = anime.typeDescription
    if note and note ~= "" then
        if hint and hint ~= "" then
            hint = hint .. "|" .. note
        else
            hint = note
        end
    end
    return {
        title = anime.animeTitle,
        hint = hint,
        value = { "script-message-to", mp.get_script_name(), "search-episodes-event", anime.animeTitle, anime.bangumiId, server },
    }
end

-- 把集数 items[2..] 嵌回 latest_menu_anime 对应 dandanplay 条目的子菜单。
-- latest_menu_anime 是 JSON 字符串快照，mark 原地变异 items 后需重嵌同步高亮。
local function embed_episodes_into_latest(items_to_embed, bangumiId, api_server)
    if latest_menu_anime and latest_menu_anime ~= "" then
        local menu_table = utils.parse_json(latest_menu_anime)
        if menu_table and type(menu_table.items) == "table" then
            for i, back_item in ipairs(menu_table.items) do
                -- 仅匹配 dandanplay 条目：聚合菜单里其它源的 value[5]/value[6]
                -- （如 maccms 的 server/vod_id）可能与 bangumiId/api_server 撞值
                if type(back_item.value) == "table" and
                back_item.value[3] == "search-episodes-event" and
                back_item.value[5] == bangumiId and back_item.value[6] == api_server then
                    menu_table.items[i].footnote = mp.get_property("filename")
                    menu_table.items[i].items = { unpack(items_to_embed, 2) }
                    break
                end
            end
            latest_menu_anime = utils.format_json(menu_table)
        end
    end
end

function get_episodes(animeTitle, bangumiId, api_server)
    local url = api_server .. "/api/v2/bangumi/" .. bangumiId
    local items = {}

    local message = "加载数据中..."
    local menu_type = "menu_episodes"
    local menu_title = "剧集信息"
    local footnote = "使用 / 打开筛选"

    if uosc_available then
        active_request_type = menu_type
        update_menu_uosc(menu_type, menu_title, message, footnote, nil, nil, "spinner",
            { "script-message-to", mp.get_script_name(), "cancel-active-request", menu_type })
    else
        show_message(message, 30)
    end

    local args = make_danmaku_request_args("GET", url)

    if args == nil then
        return
    end

    request_cancelled = false
    active_request_type = menu_type
    active_request_cancel = call_cmd_async(args, function(err, stdout)
        active_request_cancel = nil
        if request_cancelled then
            return
        end

        table.insert(items, {
            title = "↩️ 返回搜索结果",
            value = { "script-message-to", mp.get_script_name(), "open-latest-menu-anime", latest_menu_anime },
            keep_open = false,
            selectable = true,
        })

        if err then
            local message = "获取数据失败"
            if uosc_available then
                table.insert(items, {
                    title = message,
                    value = "",
                    italic = true,
                    keep_open = true,
                    selectable = false,
                    align = "center",
                })
                update_menu_uosc(menu_type, menu_title, items, footnote)
            else
                show_message(message, 3)
            end
            msg.error("HTTP 请求失败：" .. tostring(err))
            return
        end

        local response = utils.parse_json(stdout)
        if not response or not response.bangumi or not response.bangumi.episodes then
            local message = "无结果"
            if uosc_available then
                table.insert(items, {
                    title = message,
                    value = "",
                    italic = true,
                    keep_open = true,
                    selectable = false,
                    align = "center",
                })
                update_menu_uosc(menu_type, menu_title, items, footnote)
            else
                show_message(message, 3)
            end
            msg.info(message)
            return
        end

        for _, episode in ipairs(response.bangumi.episodes) do
            table.insert(items, {
                title = episode.episodeTitle,
                hint = episode.episodeNumber,
                value = { "script-message-to", mp.get_script_name(), "load-danmaku",
                animeTitle, episode.episodeTitle, episode.episodeId, api_server },
                keep_open = true,
                selectable = true,
            })
        end

        -- 把集数嵌回 latest_menu_anime 的 dandanplay 条目子菜单
        embed_episodes_into_latest(items, bangumiId, api_server)

        if uosc_available then
            footnote = mp.get_property("filename")
            -- exclusive 单选：set_episode_id 会驱逐旧 api_server 源，多标即撒谎
            remember_details_menu(menu_type, menu_title, items, footnote, true,
                { bangumiId = bangumiId, api_server = api_server })
            update_menu_uosc(menu_type, menu_title, items, footnote)
        elseif input_loaded then
            show_message("", 0)
            input.terminate()
            mp.add_timeout(0.1, function()
                open_menu_select(items)
            end)
        end
    end)
    active_request_type = menu_type
end

function update_menu_uosc(menu_type, menu_title, menu_item, menu_footnote, menu_cmd, query, message_icon, on_close)
    local items = {}
    if type(menu_item) == "string" then
        table.insert(items, {
            title = menu_item,
            value = "",
            italic = true,
            keep_open = true,
            selectable = false,
            align = "center",
            icon = message_icon or "",
        })
    else
        items = menu_item
    end

    local menu_props = {
        type = menu_type,
        title = menu_title,
        search_style = menu_cmd and "palette" or "on_demand",
        search_debounce = menu_cmd and "submit" or 0,
        on_search = menu_cmd,
        footnote = menu_footnote,
        search_suggestion = query,
        items = items,
    }

    if on_close ~= nil then
        menu_props.on_close = on_close
    end

    local current_menu_type = mp.get_property_native('user-data/uosc/menu/type')
    local cmd = "open-menu"
    if current_menu_type and tostring(current_menu_type) == tostring(menu_type) then
        cmd = "update-menu"
    end

    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", cmd, json_props)

    return json_props
end

-- ===== 选集菜单多选状态 =====
-- 点击集数后菜单保持打开（集数 item keep_open=true），已添加集数高亮回显，
-- 支持一次搜索内多源/多集叠加，免重复搜索。各站在 get-XX-event 渲染成功处
-- remember_details_menu 存快照，add-XX-event 加载后 mark_details_episode_added
-- 原地打标刷新（update-menu 同 type 原地刷，不丢滚动/选中位置）。
-- 不变式：mark 路径只变异 item 字段，绝不增删/重排 items——uosc 按索引保留
-- selected_index/scroll_y，条目错位会串位。
current_details_menu = nil
added_details_values = {}
local ADDED_HINT = "已添加"

-- value 数组逐元素 tostring 宽松相等：script-message 到达后均为 string，
-- 而 JSON 解析出的可能是 number
local function details_values_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    if #a ~= #b then return false end
    for i = 1, #a do
        if tostring(a[i]) ~= tostring(b[i]) then return false end
    end
    return true
end

-- 幂等打标：active 高亮 + hint 追加（不替换，hint 承载集数标题）
local function append_added_hint(it)
    if it.active then return end
    it.active = true
    it.hint = it.hint and (it.hint .. " | " .. ADDED_HINT) or ADDED_HINT
end

-- 打标逆操作：exclusive 换选时恢复原样
local function remove_added_hint(it)
    if not it.active then return end
    it.active = nil
    local suffix = " | " .. ADDED_HINT
    if it.hint then
        if it.hint:sub(-#suffix) == suffix then
            it.hint = it.hint:sub(1, #it.hint - #suffix)
        elseif it.hint == ADDED_HINT then
            it.hint = nil
        end
    end
end

-- 各站 get-XX-event 渲染成功后调用：先按会话注册表恢复本会话历史标记
-- （换集后注册表被 reset_details_session 清空，不会恢复过期高亮），再存快照。
-- exclusive=true 为单选语义（dandanplay：set_episode_id 驱逐旧 api_server 源，
-- 多标即撒谎）；context 存站内不透明上下文（dandanplay 的 bangumiId/api_server）。
function remember_details_menu(menu_type, menu_title, items, footnote, exclusive, context)
    for _, it in ipairs(items) do
        if type(it.value) == "table" and not it.active then
            for _, entry in ipairs(added_details_values) do
                if entry.menu_type == menu_type and details_values_equal(it.value, entry.value) then
                    append_added_hint(it)
                    break
                end
            end
        end
    end
    current_details_menu = {
        menu_type = menu_type,
        menu_title = menu_title,
        items = items,
        footnote_base = footnote or "",
        exclusive = exclusive and true or false,
        context = context,
    }
end

-- add-XX-event 里加载后调用，mark 为完整重构的 value 数组（头三元素固定
-- "script-message-to"/脚本名/"add-XX-event"，其余照抄同文件 item 构造处）。
-- 点击 = 同步登记源完成（add_danmaku_source 幂等），拉取异步、失败有
-- source_status OSD 汇总兜底——标记如实反映「已登记」。返回是否命中
-- （菜单已关/非本菜单触发时未命中，静默）。
function mark_details_episode_added(mark)
    local st = current_details_menu
    if not st or not st.items then return false end
    if st.exclusive then
        for _, it in ipairs(st.items) do
            remove_added_hint(it)
        end
        for i = #added_details_values, 1, -1 do
            if added_details_values[i].menu_type == st.menu_type then
                table.remove(added_details_values, i)
            end
        end
    end
    local hit = false
    for _, it in ipairs(st.items) do
        if type(it.value) == "table" and details_values_equal(it.value, mark) then
            append_added_hint(it)
            hit = true
        end
    end
    if not hit then return false end
    -- 注册表查重：重复点击同一集不堆积（exclusive 路径上方已清过本菜单旧条目）
    local already = false
    for _, entry in ipairs(added_details_values) do
        if entry.menu_type == st.menu_type and details_values_equal(entry.value, mark) then
            already = true
            break
        end
    end
    if not already then
        table.insert(added_details_values, { menu_type = st.menu_type, value = mark })
    end
    local n = 0
    for _, it in ipairs(st.items) do
        if it.active then n = n + 1 end
    end
    st.footnote = n > 0
        and ("已添加 " .. n .. " 个源，可继续选择或返回"
            .. (st.footnote_base ~= "" and (" · " .. st.footnote_base) or ""))
        or st.footnote_base
    if uosc_available then
        update_menu_uosc(st.menu_type, st.menu_title, st.items, st.footnote)
    end
    return true
end

-- 换集/卸载时清空会话注册表（render.lua on_unload 调用，与 source_status.reset 同点）
function reset_details_session()
    added_details_values = {}
    current_details_menu = nil
end

-- 同源单选收紧（数据层）：驱逐同 provider 的旧集源。各 load_XX_danmaku 在
-- add_danmaku_source 前调用，keep_url 为本次新选。不立即重建管线——新源到货的
-- load_danmaku 自然只剩新源（与 dandanplay set_episode_id 的驱逐语义一致）；
-- 统计台账同步移除被驱逐源（统计口径=当前视频现关联的源；set_episode_id 驱逐同款）。
-- 粘贴 URL / 历史续载路径不经此函数，多源并存不受影响。
function remove_same_provider_sources(provider, keep_url)
    if not provider then return false end
    if type(DANMAKU) ~= "table" or type(DANMAKU.sources) ~= "table" then return false end
    local removed = false
    for url, source in pairs(DANMAKU.sources) do
        if url ~= keep_url and type(source) == "table" and source.provider == provider then
            DANMAKU.sources[url] = nil
            if type(source_status) == "table" and source_status.remove then
                source_status.remove(url)
            end
            removed = true
        end
    end
    return removed
end

function open_menu_select(menu_items, is_time)
    local item_titles, item_values = {}, {}
    for i, v in ipairs(menu_items) do
        item_titles[i] = is_time and "[" .. v.hint .. "] " .. v.title or
            (v.hint and v.title .. " (" .. v.hint .. ")" or v.title)
        item_values[i] = v.value
    end
    mp.commandv('script-message-to', 'console', 'disable')
    input.select({
        prompt = is_time and '筛选:' or '选择:',
        items = item_titles,
        submit = function(id)
            input.terminate()
            perform_cancel_active_request()
            local v = item_values[id]
            if type(v) == 'table' then
                mp.commandv(unpack(v))
            elseif type(v) == 'string' then
                mp.command(v)
            end
        end,
        closed = function()
            show_message("", 0)
            input.terminate()
            perform_cancel_active_request()
        end,
    })
end

-- 打开弹幕输入搜索菜单
function open_input_menu_get()
    mp.commandv('script-message-to', 'console', 'disable')
    local title = parse_title()
    input.get({
        prompt = '番剧名称:',
        default_text = title,
        cursor_position = title and #title + 1,
        submit = function(text)
            input.terminate()
            mp.commandv("script-message-to", mp.get_script_name(), "search-anime-event", text)
        end
    })
end

function open_input_menu_uosc()
    local items = {}

    if DANMAKU.anime and DANMAKU.episode then
        -- 完整集标题（截断上限 30）：副标题是核对匹配正误的信息，不再削成「第N话」前缀
        items[#items + 1] = {
            title = string.format("已关联弹幕：%s-%s", DANMAKU.anime,
                abbr_str(DANMAKU.episode, 30)),
            bold = true,
            italic = true,
            keep_open = true,
            selectable = false,
        }
    end

    items[#items + 1] = {
        hint = "  直接搜索聚合全部来源；|tx腾讯 |yk优酷 |iq爱奇艺 |mg芒果 |biliB站 |baha巴哈 |ako番剧社区 |mdd埋堆堆 |mac采集站，|ds|dy|dm搜剧/影/漫，@备注指定弹幕服务器",
        keep_open = true,
        selectable = false,
    }

    local menu_props = {
        type = "menu_danmaku",
        title = "在此处输入番剧名称",
        search_style = "palette",
        search_debounce = "submit",
        search_suggestion = parse_title(),
        on_search = { "script-message-to", mp.get_script_name(), "search-anime-event" },
        footnote = "使用enter或ctrl+enter进行搜索",
        items = items
    }
    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
end

function open_input_menu()
    if uosc_available then
        open_input_menu_uosc()
    elseif input_loaded then
        mp.add_timeout(0.01, function()
            open_input_menu_get()
        end)
    end
end

-- 打开弹幕源添加管理菜单
function open_add_menu_get()
    local menu_log, deal_value = {}, {}

    -- 重建菜单内容函数
    local function rebuild_menu_log(select_num)
        deal_value = {}
        menu_log = {
            { text = "【既有弹幕源】", style = "{\\c&H00CCFF&\\b1}" },
            { text = "----------------------------", style = "{\\c&H888888&}" }
        }

        local serial = 0
        for url, source in pairs(DANMAKU.sources) do
            if source.data then
                if source.from == "api_server" then
                    serial = serial + 1
                    local action = source.blocked and "unblock" or "block"
                    local text = string.format("  [%02d] %s [来源：弹幕服务器%s]  ", serial, url,
                        source.blocked and "（已屏蔽）" or "（未屏蔽）")
                    local style = (tonumber(select_num) == serial) and "{\\c&HFFDE7F&\\b1}" or (action == "unblock" and "{\\c&H4C4CC3&\\b0}" or "{\\c&HCCCCCC&\\b0}")
                    deal_value[serial] = {value = url, action = action}
                    table.insert(menu_log, {text = text, style = style})
                else
                    serial = serial + 1
                    local action1 = source.blocked and "unblock" or "block"
                    local text1 = string.format("  [%02d] %s [来源：%s]%s  ", serial, source_display_title(source, url), source.provider or "用户添加", source.blocked and " (已屏蔽)" or "（未屏蔽）")
                    local style1 = (tonumber(select_num) == serial) and "{\\c&HFFDE7F&\\b1}" or (action1 == "unblock" and "{\\c&H4C4CC3&\\b0}" or "{\\c&HCCCCCC&\\b0}")
                    deal_value[serial] = {value = url, action = action1}
                    table.insert(menu_log, {text = text1, style = style1})

                    serial = serial + 1
                    local action2 = "delete"
                    local text2 = string.format("  [%02d] %s [来源：%s] (删除)  ", serial, source_display_title(source, url), source.provider or "用户添加")
                    local style2 = (tonumber(select_num) == serial) and "{\\c&HFFDE7F&\\b1}" or "{\\c&HCCCCCC&\\b0}"
                    deal_value[serial] = {value = url, action = action2}
                    table.insert(menu_log, {text = text2, style = style2})
                end
            end
        end

        if serial == 0 then
            table.insert(menu_log, { text = "        无", style = "" })
        end
    end

    -- 显示菜单
    local function show_menu(extra_lines, select_num)
        rebuild_menu_log(select_num)

        local display = {}
        for _, item in ipairs(menu_log) do table.insert(display, item) end
        table.insert(display, { text = "----------------------------", style = "{\\c&H888888&}" })

        if extra_lines then
            if #extra_lines < 2 then table.insert(display, { text = "\n", style = "" }) end
            for _, line in ipairs(extra_lines) do table.insert(display, line) end
        else
            table.insert(display, { text = "\n", style = "" })
            table.insert(display, {
                text = "提示: 输入【选项数字】可屏蔽或删除既有弹幕源",
                style = "{\\c&H999999&}"
            })
        end

        input.set_log(display)
    end

    -- 获取操作提示
    local function get_hint(action)
        local hints = {
            block = "按回车执行，屏蔽该弹幕源",
            unblock = "按回车执行，解除该弹幕源的屏蔽",
            delete = "按回车执行，删除该弹幕源"
        }
        return hints[action] or "按回车执行，获取输入源地址url的弹幕"
    end

    input.get({
        keep_open = true,
        prompt = "请在此输入源地址url: ",
        opened = function() show_menu() end,
        edited = function(text)
            text = text:gsub("^%s*(.-)%s*$", "%1")

            if text == "" then
                show_menu()
                return
            end

            local num = tonumber(text)
            local event = num and deal_value[num]
            local hint = get_hint(event and event.action)

            show_menu({
                { text = string.format("已输入: %s", text), style = "{\\c&HCCCCCC&}" },
                { text = hint, style = "{\\c&H999999&}" }
            }, text)
        end,
        submit = function(text)
            text = text:gsub("^%s*(.-)%s*$", "%1")
            if text == "" then return end

            local num = tonumber(text)
            local event = num and deal_value[num]

            if event then
                local args = string.format('{"type":"activate","value":"%s","action":"%s"}',
                    string.gsub(event.value, '\\', '\\\\'), event.action)
                mp.commandv("script-message-to", mp.get_script_name(), "setup-danmaku-source", args)
            else
                input.terminate()
                mp.commandv("script-message-to", mp.get_script_name(), "add-source-event", text)
            end

            mp.add_timeout(0.1, show_menu)
        end
    })
end

function open_add_menu_uosc()
    local sources = {}
    for url, source in pairs(DANMAKU.sources) do
        if source.data then
            local count = #source.data  -- 弹幕条数
            local count_text = string.format("（%d条）弹幕", count)
            -- 标题主、URL 缩略次之（有标题才附 URL 供排查；老记录无标题回退 URL 全显）
            local item = {title = source_display_title(source, url), value = url, keep_open = true,}
            if source.from == "api_server" then
                if source.blocked then
                    item.hint = "来源：弹幕服务器（已屏蔽）"
                    item.actions = {{icon = "check", name = "unblock", label = "解除屏蔽" .. count_text},}
                else
                    item.hint = "来源：弹幕服务器（未屏蔽）"
                    item.actions = {{icon = "not_interested", name = "block", label = "屏蔽" .. count_text},}
                end
            else
                item.hint = "来源：" .. (source.provider or "用户添加")
                if source.anime_title then
                    item.hint = item.hint .. " ｜ " .. utf8_sub(remove_query(url), 1, 50)
                end
                if source.blocked then
                    item.actions = {
                        {icon = "check", name = "unblock", label = "解除屏蔽" .. count_text},
                        {icon = "delete", name = "delete", label = "删除" .. count_text},
                    }
                else
                    item.actions = {
                        {icon = "not_interested", name = "block", label = "屏蔽" .. count_text},
                        {icon = "delete", name = "delete", label = "删除" .. count_text},
                    }
                end
            end
            table.insert(sources, item)
        end
    end
    local menu_props = {
        type = "menu_source",
        title = "在此输入源地址url",
        search_style = "palette",
        search_debounce = "submit",
        on_search = { "script-message-to", mp.get_script_name(), "add-source-event" },
        footnote = "使用enter或ctrl+enter进行添加",
        items = sources,
        item_actions_place = "outside",
        callback = {mp.get_script_name(), 'setup-danmaku-source'},
    }
    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
end

function open_add_menu()
    if uosc_available then
        open_add_menu_uosc()
    elseif input_loaded then
        mp.add_timeout(0.01, function()
            open_add_menu_get()
        end)
    end
end

-- 打开弹幕内容菜单
-- uosc 菜单项索引 -> COMMENTS 原始索引的映射。
-- 构建菜单时会过滤空文本/越界弹幕，菜单序号与数组序号错位，
-- handler 若直接用 event.index 取 COMMENTS[event.index] 会作用到错误弹幕上
local content_menu_map = {}

-- Lua pattern 魔法字符转义：把任意文本变成只匹配自身的 pattern
local function pattern_quote(s)
    return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- 「屏蔽此文本」：把该条弹幕的黑名单基准文本（合并簇显示文本、剥引擎 xN 后缀、简繁转换前）
-- 按整行字面匹配追加进黑名单文件并热重载，与管线黑名单过滤保持同一匹配语义
function block_comment_text(d)
    local path = BLACKLIST_FILE
    if not path or path == "" then
        show_message("未配置黑名单文件路径（blacklist_path）", 3)
        return
    end
    local text = (d.blacklist_key or d.clean_text or ""):gsub("^%s*(.-)%s*$", "%1")
    if text == "" then
        show_message("该弹幕无有效文本", 3)
        return
    end
    if is_text_blacklisted(text) then
        show_message("该文本已在黑名单中", 3)
        return
    end
    local file = io.open(path, "a")
    if not file then
        show_message("黑名单文件不可写：" .. path, 3)
        return
    end
    file:write("^" .. pattern_quote(text) .. "$\n")
    file:close()
    local n = reload_blacklist()
    show_message("已屏蔽该文本，黑名单共 " .. n .. " 条规则", 3)
    mp.commandv("script-message-to", "uosc", "close-menu", "menu_content")
    load_danmaku(true)
end

function open_content_menu(pos)
    local items = {}
    local time_pos = pos or mp.get_property_native("time-pos")
    local duration = mp.get_property_number("duration", 0)

    content_menu_map = {}
    if COMMENTS ~= nil then
        for idx, event in ipairs(COMMENTS) do
            local text = event.clean_text:gsub("^m%s[mbl%s%-%d%.]+$", ""):gsub("^%s*(.-)%s*$", "%1")
            local delay = event.delay
            local start_time = event.start_time
            local end_time = event.end_time
            if text and text ~= "" and start_time >= 0 and start_time <= duration then
                local delay_label_suffix = nil
                local delay_num = delay and tonumber(delay)
                if delay_num and math.abs(delay_num) > 0 then
                    delay_label_suffix = string.format("已存在延迟: %+0.1fs", delay_num)
                end

                local adjust_label = '调整弹幕延迟'
                if delay_label_suffix then
                    adjust_label = adjust_label .. '（' .. delay_label_suffix .. '）'
                end

                -- 合并簇标注 ×N（菜单里一眼看出哪些是刷屏合并来的）
                local merge_hint = (event.merge_count and event.merge_count > 1)
                    and ("×" .. event.merge_count .. "  ") or ""
                -- 源提供方标注（有记录时前缀在 URL 前，如「腾讯视频｜v.qq.com/...」）
                local src_meta = DANMAKU.sources[event.source]
                local prov_prefix = (src_meta and src_meta.provider) and (src_meta.provider .. "｜") or ""
                content_menu_map[#items + 1] = idx
                table.insert(items, {
                    title = abbr_str(text, 60),
                    hint = seconds_to_time(start_time) .. "  " .. merge_hint
                        .. "(" .. prov_prefix .. utf8_sub(remove_query(event.source), 1, 70) .. ")",
                    actions = {
                        {
                            name = 'block_source',
                            icon = 'block',
                            label = '屏蔽对应弹幕源'
                        },
                        {
                            name = 'block_text',
                            icon = 'visibility_off',
                            label = '屏蔽此文本'
                        },
                        {
                            name = 'adjust_delay',
                            icon = 'more_time',
                            label = adjust_label,
                        },
                    },
                    value = { "seek", start_time, "absolute" },
                    active = time_pos >= start_time and time_pos <= end_time,
                })
            end
        end
    end

    local menu_props = {
        type = "menu_content",
        title = "弹幕内容",
        footnote = "使用 / 打开搜索",
        items = items,
        item_actions_place = "outside",
        callback = {mp.get_script_name(), 'handle-danmaku-content-action'},
    }
    local json_props = utils.format_json(menu_props)

    if uosc_available then
        mp.commandv("script-message-to", "uosc", "open-menu", json_props)
    elseif input_loaded then
        open_menu_select(items, true)
    end
end

local menu_items_config = {
    bold = { title = "粗体", hint = options.bold, original = options.bold,
        footnote = "true / false", },
    fontsize = { title = "大小", hint = options.fontsize, original = options.fontsize,
        scope = { min = 0, max = math.huge }, footnote = "请输入整数(>=0)", },
    outline = { title = "描边", hint = options.outline, original = options.outline,
        scope = { min = 0.0, max = 4.0 }, footnote = "输入范围：(0.0-4.0)" },
    shadow = { title = "阴影", hint = options.shadow, original = options.shadow,
        scope = { min = 0, max = math.huge }, footnote = "请输入整数(>=0)", },
    scrolltime = { title = "速度", hint = options.scrolltime, original = options.scrolltime,
        scope = { min = 1, max = math.huge }, footnote = "请输入整数(>=1)", },
    opacity = { title = "透明度", hint = options.opacity, original = options.opacity,
        scope = { min = 0, max = 1 }, footnote = "输入范围：0（完全透明）到1（不透明）", },
    displayarea = { title = "弹幕显示范围", hint = options.displayarea, original = options.displayarea,
        scope = { min = 0.0, max = 1.0 }, footnote = "显示范围(0.0-1.0)", },
}
-- 创建一个包含键顺序的表，这是样式菜单的排布顺序
local ordered_keys = {"bold", "fontsize", "outline", "shadow", "scrolltime", "opacity", "displayarea"}

-- 设置弹幕样式菜单
function open_style_menu_get(query, indicator)
    mp.commandv('script-message-to', 'console', 'disable')
    local menu_log = {}

    local select_num = 0
    local select_query = nil
    if query then
        if tonumber(query) ~= nil then
            select_num = tonumber(query)
        else
            for i, v in ipairs(ordered_keys) do
                if v == query then
                    select_num = i
                end
            end
        end
        select_query = ordered_keys[select_num]
    end

    local function build_menu(source)
        menu_log = {
            { text = "【弹幕样式菜单】", style = "{\\c&H00CCFF&\\b1}" },
            { text = ("-"):rep(33), style = "{\\c&H888888&}" }
        }

        local serial = 0
        for _, key in ipairs(ordered_keys) do
            serial = serial + 1
            local config = menu_items_config[key]
            local text = string.format("  [%02d] %s   [目前：%s] ", serial, config.title, config.hint)
            text = config.hint ~= config.original and text .. "⟳" or text
            local style = serial == select_num and "{\\c&HFFDE7F&}" or "{\\c&HCCCCCC&}"
            local item_config = { text = text, style = style }
            table.insert(menu_log, item_config)
        end

        table.insert(menu_log, { text = ("-"):rep(33), style = "{\\c&H888888&}" })
        if select_num == 0 then
            table.insert(menu_log, {
                text = "注: 样式更改仅在本次播放生效",
                style = "{\\c&HFFDE7F&}"
            })
            table.insert(menu_log, {
                text = "提示: 输入【w】可上移选项，【s】可下移选项",
                style = "{\\c&H999999&}"
            })
        else
            local input_text = source and source or ""
            local config = menu_items_config[select_query]
            local suffix = ""
            if config and config.hint ~= config.original then
                suffix = "（输入\\r恢复默认配置）"
            end
            input_text = string.format("已输入%s: %s", suffix, input_text)

            local scope = config and config.footnote or ""
            local hint_text = select_query == "bold" and "提示: 输入【y】切换状态" or "提示: " .. scope
            local hint_style = "{\\c&H999999&}"
            if source and source:lower() == "\\r" then
                hint_text = string.format("提示: 回车将恢复默认配置 < %s >", config.original)
            end
            if indicator == "refresh" or indicator == "updata" then
                indicator = ""
                hint_text = "提示: 样式更改成功"
                hint_style = "{\\c&HFFDE7F&}"
                mp.add_timeout(1.5, build_menu)
            elseif indicator == "error" then
                indicator = ""
                hint_text = "提示: 输入非数字字符或范围出错"
                hint_style = "{\\c&H4C4CC3&}"
                mp.add_timeout(1.5, build_menu)
            end

            table.insert(menu_log, { text = input_text, style = "{\\c&HCCCCCC&}" })
            table.insert(menu_log, { text = hint_text, style = hint_style })
        end
        input.set_log(menu_log)
    end

    input.get({
        keep_open = true,
        prompt = "请在此输入操作（w/s|上移/下移）: ",
        opened = function() build_menu() end,
        edited = function(text)
            text = text:gsub("^%s*(.-)%s*$", "%1")

            if text == "" then
                build_menu()
                return
            end

            if text:lower() == "w" or text:lower() == "s" then
                input.terminate()
                select_num = text:lower() == "w" and select_num - 1 or select_num + 1
                select_num = (select_num > #ordered_keys) and 1 or (select_num <= 0 and #ordered_keys or select_num)
                mp.add_timeout(0.01, function()
                    open_style_menu_get(select_num)
                end)
                return
            end

            build_menu(text)
        end,
        submit = function(text)
            if select_query == nil then return end
            text = text:gsub("^%s*(.-)%s*$", "%1")
            if text == "" then return end

            if text:lower() == "\\r" then
                input.terminate()
                local args = string.format('{"type":"activate","action":"%s","index":%d}', select_query, select_num)
                mp.commandv("script-message-to", mp.get_script_name(), "setup-danmaku-style", args)
            else
                if menu_items_config[select_query]["scope"] ~= nil then
                    input.terminate()
                    mp.commandv("script-message-to", mp.get_script_name(), "setup-danmaku-style", select_query, text)
                elseif text:lower() == "y" and select_query == "bold" then
                    input.terminate()
                    local args = string.format('{"type":"activate","index":%d}', select_num)
                    mp.commandv("script-message-to", mp.get_script_name(), "setup-danmaku-style", args)
                end
            end
            return
        end
    })
end

function open_style_menu_uosc(actived, status)
    local items = {}
    for _, key in ipairs(ordered_keys) do
        local config = menu_items_config[key]
        local item_config = {
            title = config.title,
            hint = "目前：" .. tostring(config.hint),
            active = key == actived,
            keep_open = true,
            selectable = true,
        }
        if config.hint ~= config.original then
            local original_str = tostring(config.original)
            item_config.actions = {{icon = "refresh", name = key, label = "恢复默认配置 < " .. original_str .. " >"}}
        end
        table.insert(items, item_config)
    end

    local menu_props = {
        type = "menu_style",
        title = "弹幕样式",
        search_style = "disabled",
        footnote = "样式更改仅在本次播放生效",
        item_actions_place = "outside",
        items = items,
        callback = { mp.get_script_name(), 'setup-danmaku-style'},
    }

    local actions = "open-menu"
    if status ~= nil then
        -- msg.info(status)
        if status == "updata" then
            -- "updata" 模式会保留输入框文字
            menu_props.title = "  " .. menu_items_config[actived]["footnote"]
            actions = "update-menu"
        elseif status == "refresh" then
            -- "refresh" 模式会清除输入框文字
            menu_props.title = "  " .. menu_items_config[actived]["footnote"]
        elseif status == "error" then
            menu_props.title = "输入非数字字符或范围出错"
            -- 创建一个定时器，在1秒后触发回调函数，删除搜索栏错误信息
            mp.add_timeout(1.0, function() open_style_menu_uosc(actived, "updata") end)
        end
        menu_props.search_style = "palette"
        menu_props.search_debounce = "submit"
        menu_props.footnote = menu_items_config[actived]["footnote"] or ""
        menu_props.on_search = { "script-message-to", mp.get_script_name(), "setup-danmaku-style", actived }
    end

    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", actions, json_props)
end

function open_style_menu(actived, status)
    if uosc_available then
        open_style_menu_uosc(actived, status)
    elseif input_loaded then
        mp.add_timeout(0.01, function()
            open_style_menu_get(actived, status)
        end)
    else
        show_message("无支持可用的 UI框架，不支持使用该功能", 3)
    end
end

-- ============ 弹幕过滤菜单（pakku 式合并 / 模式转换 / 密度 / 黑名单） ============

local filter_menu_keys = {
    "merge_enabled", "merge_tolerance", "merge_pinyin", "merge_similarity",
    "chConvert",
    "convert_top_to_scroll", "convert_bottom_to_scroll", "scroll_threshold",
    "max_screen_danmaku", "density_control", "density_level", "blacklist_enabled",
    "reload_blacklist", "open_blacklist_location",
}

-- 档位循环设置：取值为 nil 时不参与循环。
-- 数值档（conf 覆盖后为字符串）、布尔三态档（convert_*）与字符串档（相似度强度）混用，
-- handler 侧按元素类型归一匹配
local filter_menu_presets = {
    merge_tolerance = { 5, 10, 20, 30, 60, 120 },
    max_screen_danmaku = { 0, 20, 40, 60, 80, 100 },
    merge_similarity = { "off", "light", "medium", "strong" },
    convert_top_to_scroll = { false, true, "auto" },
    convert_bottom_to_scroll = { false, true, "auto" },
    scroll_threshold = { 800, 1200, 1600, 2000, 2400 },
    chConvert = { 0, 1, 2 },
    density_control = { "off", "simple", "smart" },
    density_level = { "loose", "medium", "strict" },
}

-- 三态读取（convert_* 专用）：off / on / auto。filter_option_is_on 会把 "auto" 误判为开，不可复用
local function filter_convert_mode(key)
    local v = options[key]
    if v == "auto" then return "auto"
    elseif v == false or v == nil or v == "no" then return "off"
    else return "on" end
end

-- 开关类选项读取：conf 未覆盖时保持 Lua 布尔默认值，被 conf 覆盖时为字符串
local function filter_option_is_on(key)
    return options[key] ~= false and options[key] ~= "no"
end

-- 每次打开都从实时 options 重建，保证显示值与当前状态一致
local function filter_menu_item(key)
    local title, hint
    if key == "merge_enabled" then
        title, hint = "弹幕合并", filter_option_is_on(key) and "开" or "关"
    elseif key == "merge_tolerance" then
        local v = tonumber(options.merge_tolerance) or 30
        title, hint = "合并时间窗口", v > 0 and (v .. " 秒") or "已禁用"
    elseif key == "merge_pinyin" then
        title, hint = "拼音谐音合并", filter_option_is_on(key) and "开" or "关"
    elseif key == "merge_similarity" then
        local labels = { off = "禁用", light = "轻微", medium = "中等", strong = "强力" }
        local v = tostring(options.merge_similarity or "medium"):lower()
        title, hint = "相似度强度", labels[v] or "中等"
    elseif key == "chConvert" then
        local labels = { [0] = "关", [1] = "简体", [2] = "繁体" }
        local v = tonumber(options.chConvert) or 1
        title, hint = "简繁转换", labels[v] or "简体"
    elseif key == "convert_top_to_scroll" then
        local th = tonumber(options.scroll_threshold) or 1200
        title, hint = "顶部弹幕转滚动",
            ({ off = "关", on = "全部", auto = "自动(>" .. th .. "px)" })[filter_convert_mode(key)]
    elseif key == "convert_bottom_to_scroll" then
        local th = tonumber(options.scroll_threshold) or 1200
        title, hint = "底部弹幕转滚动",
            ({ off = "关", on = "全部", auto = "自动(>" .. th .. "px)" })[filter_convert_mode(key)]
    elseif key == "scroll_threshold" then
        local v = tonumber(options.scroll_threshold) or 1200
        title, hint = "转换宽度阈值", v > 0 and (v .. " px") or "禁用"
    elseif key == "max_screen_danmaku" then
        local v = tonumber(options.max_screen_danmaku) or 0
        title, hint = "同屏弹幕上限",
            (v > 0 and tostring(v) or "不限") .. "（仅简单模式）"
    elseif key == "density_control" then
        local labels = { off = "关闭", simple = "简单", smart = "智能" }
        local v = tostring(options.density_control or "smart"):lower()
        title, hint = "密度控制", labels[v] or "智能"
    elseif key == "density_level" then
        local labels = { loose = "宽松", medium = "中等", strict = "严格" }
        local v = tostring(options.density_level or "medium"):lower()
        title, hint = "智能密度强度", labels[v] or "中等"
    elseif key == "blacklist_enabled" then
        title, hint = "黑名单过滤", filter_option_is_on(key) and "开" or "关"
    elseif key == "reload_blacklist" then
        title, hint = "重载黑名单文件", "动作"
    elseif key == "open_blacklist_location" then
        title, hint = "打开黑名单文件位置", "动作"
    end
    return { title = title, hint = hint, value = key, keep_open = true, selectable = true }
end

-- 在系统文件管理器中定位黑名单文件（Windows: explorer /select,）
function open_blacklist_location()
    local path = BLACKLIST_FILE
    if not path or path == "" then
        show_message("未配置黑名单文件路径（blacklist_path）", 3)
        return
    end
    -- 相对路径以 mpv 工作目录补全
    if not path:match("^%a:[/\\]") and not path:match("^[/\\]") and not path:match("^~~") then
        local wd = mp.get_property("working-directory")
        if wd and wd ~= "" then
            path = utils.join_path(wd, path)
        end
    end
    if not file_exists(path) then
        show_message("黑名单文件不存在：" .. path, 3)
        return
    end
    if PLATFORM == "windows" then
        mp.command_native_async({ name = "subprocess", playback_only = false,
            args = { "explorer", "/select,", path } }, function() end)
    elseif PLATFORM == "darwin" then
        mp.command_native_async({ name = "subprocess", playback_only = false,
            args = { "open", "-R", path } }, function() end)
    else
        mp.command_native_async({ name = "subprocess", playback_only = false,
            args = { "xdg-open", utils.split_path(path) } }, function() end)
    end
end

function open_filter_menu_uosc()
    local items = {}
    for _, key in ipairs(filter_menu_keys) do
        items[#items + 1] = filter_menu_item(key)
    end
    local menu_props = {
        type = "menu_filter",
        title = "弹幕过滤",
        search_style = "disabled",
        footnote = "设置更改仅在本次播放生效，持久化请写入配置文件",
        items = items,
        callback = { mp.get_script_name(), 'setup-danmaku-filter' },
    }
    local cmd = "open-menu"
    if tostring(mp.get_property_native('user-data/uosc/menu/type')) == "menu_filter" then
        cmd = "update-menu"
    end
    mp.commandv("script-message-to", "uosc", cmd, utils.format_json(menu_props))
end

function open_filter_menu_get()
    local items = {}
    for _, key in ipairs(filter_menu_keys) do
        local item = filter_menu_item(key)
        items[#items + 1] = {
            title = item.title,
            hint = item.hint,
            value = { "script-message-to", mp.get_script_name(), "setup-danmaku-filter", key },
        }
    end
    open_menu_select(items)
end

function open_filter_menu()
    if uosc_available then
        open_filter_menu_uosc()
    elseif input_loaded then
        mp.add_timeout(0.01, function()
            open_filter_menu_get()
        end)
    else
        show_message("无支持可用的 UI框架，不支持使用该功能", 3)
    end
end

mp.register_script_message("setup-danmaku-filter", function(query)
    local event = utils.parse_json(query)
    if event == nil or event.type ~= "activate" then return end
    local key = event.value
    if key == nil then return end

    local need_rebuild = true

    if key == "reload_blacklist" then
        local n = reload_blacklist()
        show_message(string.format("已重载黑名单，共 %d 条规则", n), 3)
    elseif key == "open_blacklist_location" then
        open_blacklist_location()
        need_rebuild = false
    elseif filter_menu_presets[key] then
        -- 档位循环。conf 读入的值一律是字符串：数值档须 tonumber 归一后再匹配，
        -- 否则 "30" ~= 30 永远找不到当前档（表现为第一次点击跳到首档而非下一档）
        local presets = filter_menu_presets[key]
        local cur = (type(presets[1]) == "number") and tonumber(options[key]) or options[key]
        if type(presets[1]) == "boolean" then
            -- 布尔三态档兼容 conf 的 yes/no 写法（否则 "yes" 匹配不上 true，点击会原地踏步）
            if cur == "yes" then cur = true elseif cur == "no" then cur = false end
        end
        local idx
        for i, v in ipairs(presets) do
            if v == cur then idx = i break end
        end
        idx = idx or 1
        options[key] = presets[idx % #presets + 1]
    elseif key == "merge_enabled" or key == "merge_pinyin" or key == "blacklist_enabled" then
        options[key] = not filter_option_is_on(key)
    else
        need_rebuild = false
    end

    -- 刷新菜单显示（重建 item 列表反映新状态）
    if uosc_available then
        open_filter_menu_uosc()
    elseif input_loaded then
        mp.add_timeout(0.01, function()
            open_filter_menu_get()
        end)
    end

    -- 所有设置项都是管线级，改动后重跑合并/过滤/渲染
    if need_rebuild then
        load_danmaku(true)
    end
end)

mp.register_script_message("open_filter_danmaku_menu", function()
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_total")
    end
    open_filter_menu()
end)

-- 打开以指定时间为起点的延迟菜单
function open_delay_from_time_get(source, time, status)
    mp.commandv('script-message-to', 'console', 'disable')
    local menu_log = {}

    local function build_menu(query, input_text)
        menu_log = {
            { text = "【从该时间起调整弹幕延迟】", style = "{\\c&H00CCFF&\\b1}" },
            { text = ("-"):rep(33), style = "{\\c&H888888&}" }
        }

        table.insert(menu_log, { text = "\n", style = "" })
        local hint_text = "提示：请输入数字，单位（秒）/ 或者按照形如\"14m15s\"的格式输入分钟数加秒数"
        local hint_style = "{\\c&H999999&}"
        if status == "error" then
            hint_text = "提示: 输入非数字字符或范围出错"
            hint_style = "{\\c&H4C4CC3&}"
        end

        table.insert(menu_log, { text = input_text and ("已输入：" .. input_text) or "", style = "{\\c&HCCCCCC&}" })
        table.insert(menu_log, { text = hint_text, style = hint_style })
        input.set_log(menu_log)
    end

    input.get({
        keep_open = true,
        prompt = "请输入要设置的延迟（秒或 XmYs）: ",
        opened = function() build_menu() end,
        edited = function(text)
            text = text:gsub("^%s*(.-)%s*$", "%1")
            if text == "" then
                build_menu()
                return
            end
            build_menu(text)
        end,
        submit = function(text)
            text = text and text:gsub("^%s*(.-)%s*$", "%1") or ""
            if text == "" then return end
            input.terminate()
            local parsed = parse_delay_input(text)
            if parsed ~= nil then
                mp.commandv("script-message", "danmaku-delay", tostring(parsed), tostring(time), tostring(source))
            else
                open_delay_from_time(source, time, "error")
            end
        end
    })
end

function open_delay_from_time_uosc(source, time, status)
    if not uosc_available then
        show_message("无uosc UI框架，不支持使用该功能", 2)
        return
    end

    local menu_props = {
        type = "menu_delay_from_time",
        title = "从该时间起调整弹幕延迟",
        search_style = "palette",
        search_debounce = "submit",
        footnote = "请输入数字，单位（秒）/ 或者按照形如\"14m15s\"的格式输入分钟数加秒数",
        items = {},
        on_search = { "script-message-to", mp.get_script_name(), "setup-content-delay", tostring(time), tostring(source) },
    }

    if status == "error" then
    menu_props.title = "输入非数字字符或范围出错"
    mp.add_timeout(1.0, function() open_delay_from_time_uosc(source, time) end)
    end

    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
end

function open_delay_from_time(source, time, status)
    if uosc_available then
        open_delay_from_time_uosc(source, time, status)
    elseif input_loaded then
        mp.add_timeout(0.01, function()
            open_delay_from_time_get(source, time, status)
        end)
    else
        show_message("无支持可用的 UI框架，不支持使用该功能", 3)
    end
end

-- 弹幕源延迟菜单行 hint：手动延迟 + 时间轴对齐校正量的合计与分项。
-- 对齐介入的源实际生效偏移 = 手动段 + align_shift（管线整源平移，瞬态不落
-- delay_segments），只列手动段会恒显 0.0 秒、看不出该源被自动平移过
function format_source_delay_hint(source)
    local delay = 0
    if source.delay_segments then
        for _, seg in ipairs(source.delay_segments) do
            if seg.start == 0 then
                delay = seg.delay or 0
                break
            end
        end
    end
    if source.timeline_status and DANMAKU and DANMAKU.sources then
        for url, s in pairs(DANMAKU.sources) do if s==source then
            local raw=timeline.raw_at(url,mp.get_property_number("time-pos",0))
            if raw then return string.format("当前合计偏移:%+.2f秒 · %s",timeline.map(url,raw)-raw,source.timeline_status) end
        end end
    end
    local align = type(source.align_shift) == "number" and source.align_shift or 0
    if align ~= 0 then
        return string.format("当前弹幕源延迟:%.1f秒(对齐%+.1f/手动%+.1f)",
            delay + align + 1e-10, align, delay)
    end
    return "当前弹幕源延迟:" .. string.format("%.1f", delay + 1e-10) .. "秒"
end

-- 设置弹幕源延迟菜单
function open_delay_menu_get(source, status)
    mp.commandv('script-message-to', 'console', 'disable')
    local menu_log = {}

    local serial = 0
    local select_num = 0
    if source and tonumber(source) ~= nil then
        select_num = tonumber(source)
    end
    local select_url = nil

    local function build_menu(query, text)
        menu_log = {
            { text = "【弹幕源延迟菜单】", style = "{\\c&H00CCFF&\\b1}" },
            { text = ("-"):rep(33), style = "{\\c&H888888&}" }
        }

        serial, select_num = 0, 0
        for url, src in pairs(DANMAKU.sources) do
            if src.data and not src.blocked then
                serial = serial + 1
                select_num = (url == source) and serial or select_num
                local hint = format_source_delay_hint(src)
                local text = string.format("  [%02d] %s   [%s] ", serial, url, hint)
                local style = (serial == select_num) and "{\\c&HFFDE7F&}" or "{\\c&HCCCCCC&}"
                table.insert(menu_log, { text = text, style = style })
                select_url = serial == select_num and url or select_url
            end
        end
        if serial == 0 then
            table.insert(menu_log, { text = "        无", style = "" })
        end

        table.insert(menu_log, { text = ("-"):rep(33), style = "{\\c&H888888&}" })
        if select_num == 0 then
            table.insert(menu_log, { text = "\n", style = "" })
            table.insert(menu_log, {
                text = "提示: 输入【w】可上移选项，【s】可下移选项",
                style = "{\\c&H999999&}"
            })
        else
            local input_text = "已输入：" .. (text ~= nil and text or "")

            local hint_text = "提示：请输入数字，单位（秒）/ 或者按照形如\"14m15s\"的格式输入分钟数加秒数"
            local hint_style = "{\\c&H999999&}"
            if status == "refresh" then
                status = ""
                hint_text = "提示: 样式更改成功"
                hint_style = "{\\c&HFFDE7F&}"
                mp.add_timeout(1.5, build_menu)
            elseif status == "error" then
                status = ""
                hint_text = "提示: 输入非数字字符或范围出错"
                hint_style = "{\\c&H4C4CC3&}"
                mp.add_timeout(1.5, build_menu)
            end

--            table.insert(menu_log, { text = input_text, style = "{\\c&HCCCCCC&}" })
            table.insert(menu_log, { text = input_text, style = "{\\c&HCCCCCC&}" })
            table.insert(menu_log, { text = hint_text, style = hint_style })
        end
        input.set_log(menu_log)
    end

    input.get({
        keep_open = true,
        prompt = "请在此输入操作（w/s|上移/下移）: ",
        opened = function() build_menu() end,
        edited = function(text)
            text = text:gsub("^%s*(.-)%s*$", "%1")

            if text == "" then
                build_menu()
                return
            end

            if text:lower() == "w" or text:lower() == "s" then
                input.terminate()
                select_num = text:lower() == "w" and select_num - 1 or select_num + 1
                select_num = (select_num > serial) and 1 or (select_num <= 0 and serial or select_num)
                mp.add_timeout(0.01, function()
                    open_delay_menu_get(select_num)
                end)
                return
            end

            build_menu(select_num, text)
        end,
        submit = function(text)
            if select_url == nil then return end
            text = text:gsub("^%s*(.-)%s*$", "%1")
            if text == "" then return end

            input.terminate()
            mp.commandv("script-message-to", mp.get_script_name(), "setup-source-delay", select_url, text)
            return
        end
    })
end

function open_delay_menu_uosc(source_url, status)
    if not uosc_available then
        show_message("无uosc UI框架，不支持使用该功能", 2)
        return
    end

    local sources = {}
    for url, source in pairs(DANMAKU.sources) do
        if source.data and not source.blocked then
            local item = {title = utf8_sub(url, 1, 100), value = url, keep_open = true,}
            item.hint = format_source_delay_hint(source)
            item.active = url == source_url
            table.insert(sources, item)
        end
    end

    local menu_props = {
        type = "menu_delay",
        title = "弹幕源延迟设置",
        search_style = "disabled",
        items = sources,
        callback = {mp.get_script_name(), 'setup-source-delay'},
    }
    if source_url ~= nil then
        if status == "error" then
            menu_props.title = "输入非数字字符或范围出错"
            -- 创建一个定时器，在1秒后触发回调函数，删除搜索栏错误信息
            mp.add_timeout(1.0, function() open_delay_menu_uosc(source_url) end)
        else
            menu_props.title = "请输入数字，单位（秒）/ 或者按照形如\"14m15s\"的格式输入分钟数加秒数"
        end
        menu_props.search_style = "palette"
        menu_props.search_debounce = "submit"
        menu_props.on_search = { "script-message-to", mp.get_script_name(), "setup-source-delay", source_url }
    end

    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
end

function open_delay_menu(source, status)
    if uosc_available then
        open_delay_menu_uosc(source, status)
    elseif input_loaded then
        mp.add_timeout(0.01, function()
            open_delay_menu_get(source, status)
        end)
    else
        show_message("无支持可用的 UI框架，不支持使用该功能", 3)
    end
end

-- ===== 弹幕源统计 =====
-- 「弹幕设置」总菜单入口：逐源展示当前视频全部弹幕源的数据情况（成功条数/无数据/
-- 失败原因/等待中）+ 全局管线统计（合并/黑名单/密度/渲染条数），每源可展开详情
-- 子菜单（完整 URL/来源/缓存来源/屏蔽/延迟/时间轴校正/错误全文）。
-- 数据源：source_status.snapshot()（台账：状态+条数+原因+缓存标注，静默会话使手动
-- 路径同样留痕）∪ DANMAKU.sources（有数据但未入台账的 key 合成 done 行）。

local STATS_GLYPH = { done = "✓", empty = "○", failed = "✗", pending = "…" }
local STATS_STATUS_WORD = { done = "成功", empty = "无数据", failed = "失败", pending = "等待中" }
local STATS_FROM_LABEL = {
    user_custom = "用户添加",
    user_local = "本地文件",
    api_server = "弹幕服务器",
}

-- 行来源标签（摘要 hint 与详情行共用）：from 映射 + 记忆/缓存后缀
local function stats_from_label(r)
    local s = r.source
    local base = (s and STATS_FROM_LABEL[s.from]) or "未落源"
    if s and s.from_history then base = base .. "（记忆）" end
    if r.cache == "cache" then
        base = base .. " ·缓存"
    elseif r.cache == "stale" then
        base = base .. " ·离线缓存"
    end
    return base
end

-- 详情子菜单行（纯展示行）
local function stats_detail_row(rows, label, value)
    rows[#rows + 1] = {
        title = label .. "：" .. tostring(value),
        keep_open = true,
        selectable = false,
    }
end

local function stats_cache_word(cache)
    if cache == "cache" then return "磁盘缓存（TTL 内命中）" end
    if cache == "stale" then return "过期缓存兜底（网络失败）" end
    return "网络获取（未标注缓存命中）"
end

-- 单源详情子菜单（uosc 原生嵌套 items 展开为子页，无需回环 handler）
local function stats_source_details(r, current_duration)
    local rows = {}
    local s = r.source
    stats_detail_row(rows, "URL", r.key)
    stats_detail_row(rows, "提供方", r.provider)
    stats_detail_row(rows, "动画", r.anime or "—")
    stats_detail_row(rows, "集", r.episode or "—")
    stats_detail_row(rows, "源视频时长", source_duration.valid(r.duration_seconds)
        and source_duration.format(r.duration_seconds) or (r.duration_pending and "时长查询中" or "时长未知"))
    stats_detail_row(rows, "当前视频时长", source_duration.format(current_duration))
    local diff = source_duration.diff_text(r.duration_seconds, current_duration)
    stats_detail_row(rows, "时长差", diff == "无法比较" and diff or (diff .. "（源视频 − 当前视频）"))
    if source_duration.valid(r.duration_seconds) and source_duration.valid(current_duration)
        and math.abs(r.duration_seconds-current_duration)<=2 then
        stats_detail_row(rows, "版本线索", "时长接近，疑似同版本；仍须内容验证")
    end
    local info=r.duration_info
    if info and source_duration.valid(info.reference_seconds) then
        stats_detail_row(rows,"目录参考时长",source_duration.format(info.reference_seconds))
        local ref_diff=source_duration.diff_text(info.reference_seconds,current_duration)
        stats_detail_row(rows,"参考时长差",ref_diff=="无法比较" and ref_diff or (ref_diff.."（目录参考 − 当前视频）"))
    end
    if not source_duration.valid(r.duration_seconds) and not r.duration_pending and info and info.reason then
        stats_detail_row(rows,"时长说明",info.reason)
    end
    stats_detail_row(rows, "弹幕条数", r.count ~= nil and r.count or "—")
    stats_detail_row(rows, "来源", stats_from_label(r))
    stats_detail_row(rows, "缓存来源", stats_cache_word(r.cache))
    if s then
        stats_detail_row(rows, "屏蔽", s.blocked and "是（未参与渲染）" or "否")
        local delay_text = "无"
        if type(s.delay_segments) == "table" then
            for _, seg in ipairs(s.delay_segments) do
                if seg.start == 0 then
                    delay_text = string.format("%+.1f 秒", (seg.delay or 0) + 1e-10)
                    break
                end
            end
        end
        stats_detail_row(rows, "手动延迟", delay_text)
        if s.timeline_relation_status then stats_detail_row(rows, "源间关联", s.timeline_relation_status) end
        if s.timeline_local_status then stats_detail_row(rows, "本地视频", s.timeline_local_status) end
        if s.timeline_relation_detail then stats_detail_row(rows, "关联依据", s.timeline_relation_detail) end
        if type(s.align_shift) == "number" and s.align_shift ~= 0 then
            stats_detail_row(rows, "时间轴校正", string.format("%+.2f 秒", s.align_shift))
        else
            stats_detail_row(rows, "时间轴校正", "未介入")
        end
    else
        stats_detail_row(rows, "源记录", "无（失败/未到货，未落源）")
    end
    if r.error and (r.status == "failed" or r.status == "empty") then
        stats_detail_row(rows, r.status == "empty" and "无数据原因" or "错误信息", r.error)
    elseif r.error and r.status == "pending" then
        stats_detail_row(rows, "进行中备注", r.error)
    end
    return rows
end

-- 组装统计菜单 items（纯函数：不读任何全局——快照/源表/管线统计由调用方折进参数，
-- 供打开/原地刷新/单测三方共用）。
-- entries: source_status.snapshot().entries；sources: DANMAKU.sources（只读引用）；
-- pipeline: { total=渲染条数|nil, merge=MERGE_STATS|nil, blacklist=…, density=… }
-- current_duration: mpv 总时长（秒）；pending_durations: URL -> 查询中（可选）。
-- 排序键 = provider..url（与总菜单「已关联弹幕」区同款、不含 status）——状态迁移
-- 永不重排，满足 update-menu 按索引保留选中/滚动位置的不变式（本文件 252 行注释）
function build_source_stats_items(entries, sources, pipeline, current_duration, pending_durations, duration_details)
    sources = (type(sources) == "table") and sources or {}
    -- 台账为基；源表中有数据但未入台账的 key（B站合集/历史重放壳等）合成 done 行
    local rows = {}
    local seen = {}
    for _, e in ipairs(entries or {}) do
        local s = sources[e.key]
        rows[#rows + 1] = {
            key = e.key,
            provider = e.provider or (type(s) == "table" and s.provider)
                or provider_label_from_url(e.key) or "弹幕源",
            anime = e.anime,
            episode = e.episode,
            status = e.status or "pending",
            count = e.count,
            error = e.error,
            cache = e.cache,
            duration_seconds = source_duration.valid(type(s)=="table" and s.duration_seconds)
                or source_duration.valid(e.duration_seconds),
            duration_pending = pending_durations and pending_durations[e.key],
            duration_info = duration_details and duration_details[e.key],
            source = (type(s) == "table") and s or nil,
        }
        seen[e.key] = true
    end
    for url, s in pairs(sources) do
        if not seen[url] and type(s) == "table" and type(s.data) == "table" and #s.data > 0 then
            rows[#rows + 1] = {
                key = url,
                provider = s.provider or provider_label_from_url(url) or "弹幕源",
                anime = s.anime_title,
                episode = s.episode_title,
                status = "done",
                count = #s.data,
                duration_seconds = source_duration.valid(s.duration_seconds),
                duration_pending = pending_durations and pending_durations[url],
                duration_info = duration_details and duration_details[url],
                source = s,
            }
        end
    end
    table.sort(rows, function(a, b)
        return a.provider .. a.key < b.provider .. b.key
    end)

    -- 空态：台账与源表皆无记录
    if #rows == 0 then
        return { {
            title = "当前视频暂无弹幕源记录",
            italic = true,
            keep_open = true,
            selectable = false,
            align = "center",
        } }
    end

    local items = {}
    local n = { done = 0, empty = 0, failed = 0, pending = 0 }
    for _, r in ipairs(rows) do n[r.status] = (n[r.status] or 0) + 1 end
    items[#items + 1] = {
        title = string.format("源统计（共 %d 个）", #rows),
        hint = "当前视频时长：" .. source_duration.format(current_duration),
        bold = true,
        keep_open = true,
        selectable = false,
    }
    items[#items + 1] = {
        title = string.format("  成功 %d · 无数据 %d · 失败 %d · 等待 %d",
            n.done, n.empty, n.failed, n.pending),
        muted = true,
        keep_open = true,
        selectable = false,
    }
    -- 管线统计（与 show_loaded OSD 同口径，有值才显示；渲染条数有则恒显）
    if type(pipeline) == "table" then
        local m = pipeline.merge
        if type(m) == "table" and m.before and m.after and m.before > m.after then
            items[#items + 1] = {
                title = string.format("  已合并 %d 条相似弹幕（%d→%d）",
                    m.before - m.after, m.before, m.after),
                muted = true,
                keep_open = true,
                selectable = false,
            }
        end
        local b = pipeline.blacklist
        if type(b) == "table" and b.dropped and b.dropped > 0 then
            items[#items + 1] = {
                title = string.format("  黑名单：过滤 %d 条", b.dropped),
                muted = true,
                keep_open = true,
                selectable = false,
            }
        end
        local d = pipeline.density
        if type(d) == "table" and (d.shrunk > 0 or d.dropped > 0) then
            items[#items + 1] = {
                title = string.format("  智能密度：缩小 %d 条，丢弃 %d 条", d.shrunk, d.dropped),
                muted = true,
                keep_open = true,
                selectable = false,
            }
        end
        if pipeline.total ~= nil then
            items[#items + 1] = {
                title = string.format("  最终渲染 %d 条", pipeline.total),
                muted = true,
                keep_open = true,
                selectable = false,
            }
        end
    end
    -- 逐源行（selectable：点开展开详情子菜单）
    for _, r in ipairs(rows) do
        local title_src = r.source or { anime_title = r.anime, episode_title = r.episode }
        items[#items + 1] = {
            title = string.format("%s %s%s", STATS_GLYPH[r.status] or "…",
                r.provider, source_display_title(title_src, r.key, 60)),
            hint = ((r.count ~= nil) and (r.count .. "条") or "—")
                .. " · " .. stats_from_label(r)
                .. " · " .. (STATS_STATUS_WORD[r.status] or "等待中")
                .. " · " .. source_duration.summary(r.duration_seconds, current_duration, r.duration_pending, r.duration_info),
            keep_open = true,
            selectable = true,
            items = stats_source_details(r, current_duration),
        }
    end
    return items
end

-- 管线统计快照（全局折进 build 参数；COMMENTS/各统计变量由 parse.lua 管线重建置 nil）
local function source_stats_pipeline()
    return {
        total = type(COMMENTS) == "table" and #COMMENTS or nil,
        merge = MERGE_STATS,
        blacklist = BLACKLIST_STATS,
        density = DENSITY_STATS,
    }
end

-- 组装 menu_props（打开与原地刷新共用；search_style=disabled 须自组装——
-- update_menu_uosc 的 search_style 硬编码 palette/on_demand）
local function source_stats_menu_props()
    local entries = source_status.snapshot().entries
    local pending,details = {},{}
    for _, e in ipairs(entries) do pending[e.key]=source_duration.pending(e.key);details[e.key]=source_duration.info(e.key) end
    for key in pairs(DANMAKU.sources) do pending[key]=source_duration.pending(key);details[key]=source_duration.info(key) end
    local props = {
        type = "menu_stats",
        title = "弹幕源统计",
        search_style = "disabled",
        items = build_source_stats_items(entries, DANMAKU.sources, source_stats_pipeline(),
            mp.get_property_number("duration"), pending, details),
    }
    local fn = mp.get_property("filename")
    if fn then props.footnote = fn end
    return props
end

function open_source_stats_menu_uosc()
    source_duration.query(source_status.snapshot().entries, DANMAKU.sources)
    mp.commandv("script-message-to", "uosc", "open-menu",
        utils.format_json(source_stats_menu_props()))
end

-- 无 uosc 回退：OSD 汇总 dump + 逐源详情镜像控制台（不做交互式逐源详情）
function show_source_stats_osd()
    source_duration.query(source_status.snapshot().entries, DANMAKU.sources)
    local current = mp.get_property_number("duration")
    local entries=source_status.snapshot().entries
    local details,pending={},{}
    for _,e in ipairs(entries) do details[e.key]=source_duration.info(e.key);pending[e.key]=source_duration.pending(e.key) end
    for key in pairs(DANMAKU.sources) do details[key]=source_duration.info(key);pending[key]=source_duration.pending(key) end
    local items = build_source_stats_items(entries, DANMAKU.sources, nil, current, pending, details)
    local lines = {}
    for _, row in ipairs(items) do
        if row.items then
            lines[#lines + 1] = "弹幕源 " .. row.title .. " · " .. row.hint
            for _, detail in ipairs(row.items) do msg.info(detail.title) end
        end
    end
    if #lines > 0 then table.insert(lines, 1, "当前视频时长：" .. source_duration.format(current)) end
    local p = source_stats_pipeline()
    local stats = {}
    if type(p.merge) == "table" and p.merge.before and p.merge.after and p.merge.before > p.merge.after then
        stats[#stats + 1] = string.format("已合并 %d 条（%d→%d）",
            p.merge.before - p.merge.after, p.merge.before, p.merge.after)
    end
    if type(p.blacklist) == "table" and p.blacklist.dropped and p.blacklist.dropped > 0 then
        stats[#stats + 1] = string.format("黑名单过滤 %d 条", p.blacklist.dropped)
    end
    if type(p.density) == "table" and (p.density.shrunk > 0 or p.density.dropped > 0) then
        stats[#stats + 1] = string.format("密度缩 %d 弃 %d", p.density.shrunk, p.density.dropped)
    end
    if p.total ~= nil then stats[#stats + 1] = string.format("渲染 %d 条", p.total) end
    if #lines > 0 then
        local text = table.concat(lines, "\\N")
        if #stats > 0 then text = text .. "\\N" .. table.concat(stats, " · ") end
        show_message(text, 10)
    else
        show_message("当前视频暂无弹幕源记录", 5)
    end
    for _, line in ipairs(lines) do msg.info(line) end
    for _, e in ipairs(source_status.snapshot().entries) do
        msg.info(string.format("[源统计] %s %s | %s%s", e.status or "?",
            e.provider or "弹幕源", e.key, e.error and (" | " .. e.error) or ""))
    end
end

function open_source_stats_menu()
    if uosc_available then
        open_source_stats_menu_uosc()
    else
        show_source_stats_osd()
    end
end

-- 统计菜单开着时原地刷新（set_on_change 台账变异 + show_loaded 到货双触发；
-- 未开着直接返回，mark 频率低、属性读取开销可忽略）
function refresh_source_stats_menu()
    if not uosc_available then return end
    local current = mp.get_property_native('user-data/uosc/menu/type')
    if not current or tostring(current) ~= "menu_stats" then return end
    source_duration.query(source_status.snapshot().entries, DANMAKU.sources)
    mp.commandv("script-message-to", "uosc", "update-menu",
        utils.format_json(source_stats_menu_props()))
end

-- 总集合弹幕菜单
local total_menu_items_config = {
    { title = "弹幕搜索", action = "open_search_danmaku_menu" },
    { title = "从源添加弹幕", action = "open_add_source_menu" },
    { title = "时间轴校准", action = "open_timeline_calibration_menu" },
    { title = "弹幕源延迟设置", action = "open_source_delay_menu" },
    { title = "弹幕整体偏移", action = "open_global_danmaku_delay_menu" },
    { title = "弹幕样式", action = "open_danmaku_style_menu" },
    { title = "弹幕过滤", action = "open_filter_danmaku_menu" },
    { title = "弹幕内容", action = "open_content_danmaku_menu" },
    { title = "弹幕源统计", action = "open_source_stats_menu" },
    { title = "高能时间轴", action = "toggle_density_timeline" },
    { title = "清空弹幕缓存", action = "clear-danmaku-cache" },
}

function open_add_total_menu_uosc()
    local items = {}

    -- 逐源列出已加载弹幕（与 OSD 汇总/源菜单口径一致）；无已加载源时回退记录级单行
    local titled = {}
    for url, source in pairs(DANMAKU.sources) do
        if source.data and type(source.data) == "table" and #source.data > 0 then
            titled[#titled + 1] = {url = url, source = source}
        end
    end
    if #titled > 0 then
        -- pairs 遍历序不稳定，按显示名排序保证确定性
        table.sort(titled, function(a, b)
            local ka = (a.source.provider or provider_label_from_url(a.url) or "弹幕源") .. a.url
            local kb = (b.source.provider or provider_label_from_url(b.url) or "弹幕源") .. b.url
            return ka < kb
        end)
        items[#items + 1] = {
            title = "已关联弹幕",
            bold = true,
            keep_open = true,
            selectable = false,
        }
        local max_rows = 4
        for i = 1, math.min(#titled, max_rows) do
            local t = titled[i]
            items[#items + 1] = {
                title = string.format("  %s%s（%d条）",
                    (t.source.provider or provider_label_from_url(t.url) or "弹幕源"),
                    source_display_title(t.source, t.url), #t.source.data),
                muted = true,
                keep_open = true,
                selectable = false,
            }
        end
        if #titled > max_rows then
            items[#items + 1] = {
                title = string.format("  …等 %d 个弹幕源", #titled - max_rows),
                muted = true,
                keep_open = true,
                selectable = false,
            }
        end
    elseif DANMAKU.anime and DANMAKU.episode then
        items[#items + 1] = {
            title = string.format("已关联弹幕：%s-%s", DANMAKU.anime,
                abbr_str(DANMAKU.episode, 30)),
            bold = true,
            italic = true,
            keep_open = true,
            selectable = false,
        }
    end

    for _, config in ipairs(total_menu_items_config) do
        table.insert(items, {
            title = config.title,
            value = { "script-message-to", mp.get_script_name(), config.action },
            keep_open = false,
            selectable = true,
        })
    end

    local menu_props = {
        type = "menu_total",
        title = "弹幕设置",
        search_style = "disabled",
        items = items,
    }
    local json_props = utils.format_json(menu_props)
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
end

function open_add_total_menu_select()
    local item_titles, item_values = {}, {}
    for i, config in ipairs(total_menu_items_config) do
        item_titles[i] = config.title
        item_values[i] = { "script-message-to", mp.get_script_name(), config.action }
    end

    mp.commandv('script-message-to', 'console', 'disable')
    input.select({
        prompt = '选择:',
        items = item_titles,
        submit = function(id)
            local cmd = item_values[id]
            mp.add_timeout(0.1, function()
                mp.commandv(unpack(cmd))
            end)
        end,
    })
end

function open_add_total_menu()
    if uosc_available then
        open_add_total_menu_uosc()
    elseif input_loaded then
        open_add_total_menu_select()
    end
end

function toggle_danmaku_switch(value)
    mp.commandv("script-message-to", "uosc", "set", "show_danmaku", value)
    mp.set_property_bool(DANMAKU_SWITCH_ON, value == "on")
end

mp.commandv(
    "script-message-to",
    "uosc",
    "set-button",
    "danmaku",
    utils.format_json({
        icon = "search",
        tooltip = "弹幕搜索",
        command = "script-message open_search_danmaku_menu",
    })
)

mp.commandv(
    "script-message-to",
    "uosc",
    "set-button",
    "danmaku_source",
    utils.format_json({
        icon = "add_box",
        tooltip = "从源添加弹幕",
        command = "script-message open_add_source_menu",
    })
)

mp.commandv(
    "script-message-to",
    "uosc",
    "set-button",
    "danmaku_styles",
    utils.format_json({
        icon = "palette",
        tooltip = "弹幕样式",
        command = "script-message open_danmaku_style_menu",
    })
)

mp.commandv(
    "script-message-to",
    "uosc",
    "set-button",
    "danmaku_delay",
    utils.format_json({
        icon = "more_time",
        tooltip = "弹幕源延迟设置",
        command = "script-message open_source_delay_menu",
    })
)

mp.commandv(
    "script-message-to",
    "uosc",
    "set-button",
    "danmaku_menu",
    utils.format_json({
        icon = "grid_view",
        tooltip = "弹幕设置",
        command = "script-message open_add_total_menu",
    })
)


-- 勿在此重复依赖唯一注册：density_timeline.lua 在本模块之后加载，其对 uosc-version
-- 的接管注册已含置位 uosc_available（mpv 同一脚本内同名消息仅一处理器、后注册覆盖）
mp.register_script_message('uosc-version', function()
    uosc_available = true
end)

mp.commandv("script-message-to", "uosc", "set", "show_danmaku", "off")
mp.register_script_message("set", function(prop, value)
    if prop ~= "show_danmaku" then
        return
    end

    if value == "on" then
        ENABLED = true
        if COMMENTS == nil then
            set_danmaku_visibility(true)
            local path = mp.get_property("path")
            init(path)
        else
            show_loaded()
            show_danmaku_func()
        end
    else
        show_message("关闭弹幕", 2)
        ENABLED = false
        hide_danmaku_func()
    end

    toggle_danmaku_switch(value)
end)

-- 注册函数给 uosc 按钮使用
mp.register_script_message("search-anime-event", function(query)
    perform_cancel_active_request()
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_danmaku")
    end
    local name, class = query:match("^(.-)%s*|%s*(.-)%s*$")
    if name and class then
        class = class:lower()
        if class == "tx" then
            query_tencent_search(name)
        elseif class == "mac" then
            query_maccms_search(name)
        elseif class == "yk" then
            query_youku_search(name)
        elseif class == "iq" then
            query_iqiyi_search(name)
        elseif class == "mg" then
            query_mgtv_search(name)
        elseif class == "bili" then
            query_bilibili_search(name)
        elseif class == "baha" then
            query_bahamut_search(name)
        elseif class == "ako" then
            query_animeko_search(name)
        elseif class == "mdd" then
            query_maiduidui_search(name)
        elseif class == "acf" then
            query_acfun_search(name)
        elseif class == "ezd" then
            query_ezdmw_search(name)
        elseif class == "ggl" then
            query_ggl_search(name)
        elseif class == "ayf" then
            query_aiyifan_search(name)
        elseif class == "cyc" then
            query_cyc_search(name)
        elseif class == "omf" then
            query_omofun_search(name)
        else
            query_extra(name, class)
        end
        return
    end
    local filter_note = nil
    local search_name = query
    local at_pos = query:find("@[^@]*$")
    if at_pos then
        search_name = query:sub(1, at_pos-1):gsub("%s+$", "")
        filter_note = query:sub(at_pos+1):gsub("^%s*(.-)%s*$", "%1")
        if filter_note == "" then filter_note = nil end
    end
    -- 纯关键词 → 多源聚合搜索（modules/search_hub.lua）
    search_hub.multi_source_search(search_name, filter_note)
end)

mp.register_script_message("search-episodes-event", function(animeTitle, bangumiId, api_server)
    perform_cancel_active_request()
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_anime")
    end

    get_episodes(animeTitle, bangumiId, api_server)
end)

mp.register_script_message("load-danmaku", function(animeTitle, episodeTitle, episodeId, api_server)
    ENABLED = true
    DANMAKU.anime = animeTitle
    DANMAKU.episode = episodeTitle
    -- meta 补传：源条目/统计台账此前拿不到标题只能显示 URL 截断
    set_episode_id(episodeId, true, api_server,
        { anime = animeTitle, episode = episodeTitle })
    -- 多选：打标 + 原地刷新 menu_episodes；重嵌 latest_menu_anime 同步嵌套子菜单高亮
    if mark_details_episode_added({ "script-message-to", mp.get_script_name(),
        "load-danmaku", animeTitle, episodeTitle, episodeId, api_server }) then
        local st = current_details_menu
        if st and st.menu_type == "menu_episodes" and st.context then
            embed_episodes_into_latest(st.items, st.context.bangumiId, st.context.api_server)
        end
    end
end)

mp.register_script_message("add-source-event", function(query)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_source")
    end
    ENABLED = true
    add_danmaku_source(query, true, provider_label_from_url(query))
end)

mp.register_script_message("open_danmaku_style_menu", function()
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_total")
    end
    open_style_menu()
end)

mp.register_script_message("open_content_danmaku_menu", function()
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_total")
    end
    open_content_menu()
end)

mp.register_script_message("open-latest-menu-anime", function ()
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "open-menu", latest_menu_anime)
    elseif input_loaded then
        show_message("", 0)
        mp.add_timeout(0.1, function()
            open_menu_select(utils.parse_json(latest_menu_anime))
        end)
    end
end)

mp.register_script_message('cancel-active-request', function(menu_type)
    perform_cancel_active_request(menu_type)
end)

mp.register_script_message("setup-danmaku-style", function(query, text)
    local event = utils.parse_json(query)
    if event ~= nil then
        -- item点击 或 图标点击
        if event.type == "activate" then
            if not event.action then
                if ordered_keys[event.index] == "bold" then
                    options.bold = not options.bold
                    menu_items_config.bold.hint = options.bold and "true" or "false"
                end
                -- "updata" 模式会保留输入框文字
                open_style_menu(ordered_keys[event.index], "updata")
                return
            else
                -- msg.info("event.action：" .. event.action)
                options[event.action] = menu_items_config[event.action]["original"]
                menu_items_config[event.action]["hint"] = options[event.action]
                open_style_menu(event.action, "updata")
                if event.action == "fontsize" or event.action == "scrolltime" then
                    load_danmaku(true)
                end
            end
        end
    else
        -- 数值输入
        if text == nil or text == "" then
            return
        end
        local newText, _ = text:gsub("%s", "") -- 移除所有空白字符
        if tonumber(newText) ~= nil and menu_items_config[query]["scope"] ~= nil then
            local num = tonumber(newText)
            local min_num = menu_items_config[query]["scope"]["min"]
            local max_num = menu_items_config[query]["scope"]["max"]
            if num and min_num <= num and num <= max_num then
                if string.match(menu_items_config[query]["footnote"], "整数") then
                    -- 输入范围为整数时向下取整
                    num = tostring(math.floor(num))
                end
                options[query] = tostring(num)
                menu_items_config[query]["hint"] = options[query]
                -- "refresh" 模式会清除输入框文字
                open_style_menu(query, "refresh")
                if query == "fontsize" or query == "scrolltime" then
                    load_danmaku(true, true)
                end
                return
            end
        end
        open_style_menu(query, "error")
    end
end)

mp.register_script_message('setup-danmaku-source', function(json)
    local event = utils.parse_json(json)
    if event.type == 'activate' then

        if event.action == "delete" then
            DANMAKU.sources[event.value] = nil
            -- 统计台账同步移除（源管理菜单删除的源不再出现在弹幕源统计）
            if type(source_status) == "table" and source_status.remove then
                source_status.remove(event.value)
            end
            remove_source_from_history(event.value)
            -- 同步删除文件夹级B站记忆（否则下一集又会自动复活）
            if remove_bilibili_series_record_for_url(event.value) then
                show_message("已清除本文件夹的B站弹幕记忆", 3)
            end
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_source")
            open_add_menu()
            load_danmaku(true)
        end

        if event.action == "block" then
            DANMAKU.sources[event.value]["blocked"] = true
            add_source_to_history(event.value, DANMAKU.sources[event.value])
            sync_bilibili_series_source(event.value, { blocked = true })
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_source")
            open_add_menu()
            load_danmaku(true)
        end

        if event.action == "unblock" then
            DANMAKU.sources[event.value]["blocked"] = false
            add_source_to_history(event.value, DANMAKU.sources[event.value])
            sync_bilibili_series_source(event.value, { blocked = false })
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_source")
            open_add_menu()
            load_danmaku(true)
        end
    end
end)

mp.register_script_message("setup-source-delay", function(query, text)
    local event = utils.parse_json(query)
    if event ~= nil then
        -- item点击
        if event.type == "activate" then
            open_delay_menu(event.value)
        end
    else
        -- 数值输入
        if text == nil or text == "" then
            return
        end
        local delay = parse_delay_input(text)
        if delay ~= nil then
            mp.commandv("script-message", "danmaku-delay", tostring(delay), "0", tostring(query))
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_delay")
            mp.add_timeout(0.1, function()
                open_delay_menu(query, "refresh")
            end)
        else
            open_delay_menu(query, "error")
        end
    end
end)

mp.register_script_message('handle-danmaku-content-action', function(json)
    local event = utils.parse_json(json)
    if not event or event.type ~= 'activate' then return end

    if event.action then
        local d = COMMENTS[content_menu_map[event.index]]
        if not d then return end

        if event.action == "block_source" then
            if not d.source then return end
            DANMAKU.sources[d.source]["blocked"] = true
            add_source_to_history(d.source, DANMAKU.sources[d.source])
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_content")
            load_danmaku(true)
        elseif event.action == "block_text" then
            block_comment_text(d)
        elseif event.action == "adjust_delay" then
            if not d.source then return end
            -- 打开以该弹幕时间为起点的延迟菜单（该延迟将作用于该时间点及之后的弹幕），仅针对该条弹幕的 source
            mp.commandv("script-message", "open_content_delay_menu", d.source, tostring(d.start_time))
        end
    else
        if event.value then
            if type(event.value) == "table" then
                mp.commandv(unpack(event.value))
            else
                mp.command(event.value)
            end
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_content")
        end
    end
end)

mp.register_script_message("open_content_delay_menu", function(source, time)
    open_delay_from_time(source, tonumber(time))
end)

mp.register_script_message("setup-content-delay", function(...)
    local args = {...}
    if #args == 1 then
        return
    end
    if #args >= 2 then
        local time = tonumber(args[1])
        local source = args[2]
        local delay_str = args[3]
        local delay = parse_delay_input(delay_str)
        if delay ~= nil then
            mp.commandv("script-message", "danmaku-delay", tostring(delay), tostring(time), tostring(source))
            mp.commandv("script-message-to", "uosc", "close-menu", "menu_delay_from_time")
        else
            open_delay_from_time(source, tonumber(time), "error")
        end
    end
end)

-- 统计菜单自动刷新挂钩：台账变异（登记/终态/软备注/删除/重置）时若菜单开着原地
-- 刷新（守卫式注入：menu-only 单测环境无 source_status 全局时静默跳过）
if type(source_status) == "table" and type(source_status.set_on_change) == "function" then
    source_status.set_on_change(function()
        refresh_source_stats_menu()
    end)
end

mp.observe_property("duration", "number", function() refresh_source_stats_menu() end)
