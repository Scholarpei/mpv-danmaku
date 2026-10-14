-- 次元城（CYCity / cycani.org）关键词搜索流程（搜索后缀 |cyc）
-- 接口（全部 www.cycani.org，见 modules/cyc_parse.lua；⚠️ 全站弹幕生态里量级最高的
-- 直连源之一——芙莉莲 ep1 实测 862 条，2026-10 仍在流入）：
--   /api/videos/search?q=<kw>（英文关键词直达：english_title 参与匹配，"frieren"
--   可搜到中文条目，不接 TMDB 换译名）→ 条目 {video_id, title, year, total} →
--   选条目后拉 /api/videos/{id}/sections 分集表（sites/cyc.lua fetch_cyc_sections：
--   会话级缓存 + page_size=100 串行翻页，长番海贼王 1155 集 12 页取满）渲染选集菜单 →
--   选集后拼 https://www.cycani.org/anime/{video_id}/play/{集序号} 规范 URL 交给
--   add_danmaku_source 现有管线（cycani.org 域名跳过 extcomment 直连 sites/cyc.lua）
-- 多季番为独立 video 条目（S1/S2 各自搜到各自选），无跨季复合集数问题
-- 历史续载：DANMAKU.extra 记 kind="cyc"（含 video_id/title/year），换集时重取分集表
--   按集序号定位目标集（会话缓存命中零网络），main.lua 的 dandanplay_flow 按 kind 分发

local msg = require("mp.msg")
local utils = require("mp.utils")
local cparse = require("modules/cyc_parse")

local BASE = "https://www.cycani.org"
local SEARCH_URL = BASE .. "/api/videos/search?q="
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

local function build_get_args(url)
    local args = {
        'curl', '-L', '-s', '--ssl-no-revoke', '--compressed',
        '--user-agent', UA,
        '-H', 'x-app-name: cyc_web',
    }
    if options.cookie_file and options.cookie_file ~= '' then
        args[#args + 1] = '-b'
        args[#args + 1] = mp.command_native({ 'expand-path', options.cookie_file })
    end
    if options.proxy ~= '' then
        args[#args + 1] = '-x'
        args[#args + 1] = options.proxy
    end
    append_curl_timeout(args)
    args[#args + 1] = url
    return args
end

local function fetch_page(url, timeout, callback)
    call_cmd_async_with_timeout(build_get_args(url), timeout, function(err, out)
        if err or not out or out == '' then
            callback(nil)
            return
        end
        callback(out)
    end)
end

-- ============ 选集后加载（菜单选集与历史续载共用） ============

local function load_cyc_danmaku(video_id, ep, title, year)
    ENABLED = true
    DANMAKU.anime = title .. " (" .. (tonumber(year) or 0) .. ")"
    DANMAKU.episode = "第" .. ep .. "集"
    DANMAKU.source = "cyc"
    DANMAKU.extra = {
        kind = "cyc",
        video_id = tostring(video_id),
        title = title,
        year = tonumber(year) or 0,
        episodenum = tonumber(ep) or 1,
    }
    write_history()
    -- 同源单选收紧：驱逐次元城旧集源（标记层 exclusive 同步，见 add-cyc-event）
    local src_url = ("https://www.cycani.org/anime/%s/play/%s"):format(video_id, ep)
    remove_same_provider_sources("次元城", src_url)
    add_danmaku_source(src_url, true, "次元城",
        { anime = DANMAKU.anime, episode = DANMAKU.episode, kind = "cyc" })
end

-- 历史续载入口：按 kind="cyc" 记录重取分集表、按集序号定位目标集，由 main.lua 调入；
-- 超出集数按确定性无弹幕上报（不静默、不走 dmku 兜底）
function resume_cyc_episode(extra, episodenum)
    fetch_cyc_sections(extra.video_id, function(entry)
        if not entry then
            source_status.mark_failed("extra:cyc", "无法获取分集表", "次元城弹幕续载失败")
            return
        end
        if episodenum < 1 or episodenum > #entry.episodes then
            source_status.mark_failed("extra:cyc",
                ("第 %d 集｜共 %d 集"):format(episodenum, #entry.episodes), "次元城弹幕续载失败")
            return
        end
        load_cyc_danmaku(extra.video_id, episodenum, extra.title, extra.year)
    end)
end

-- 下一集预取：目标集数 → 拉弹幕写 cyc: 磁盘缓存（sites/cyc.lua；仅取分集表与弹幕，
-- 无 OSD/history/sources 副作用，与 resume 路径同源）
function prefetch_cyc_episode(extra, episodenum, callback)
    callback = callback or function() end
    fetch_cyc_sections(extra.video_id, function(entry)
        if not entry or episodenum < 1 or episodenum > #entry.episodes then
            callback(false)
            return
        end
        prefetch_cyc_danmaku(extra.video_id, episodenum, callback)
    end)
end

-- ============ 搜索 ============

-- 搜索解析结果 → menu_anime 条目（|cyc 单源流与聚合搜索共用；hint: 年份|集数|站点，
-- 单集条目标「剧场版」——total==1 即剧场版/OVA 形态）
function build_cyc_search_items(parsed_items)
    local items = {}
    for _, it in ipairs(parsed_items) do
        local total_hint
        if it.total > 1 then
            total_hint = it.total .. "集"
        elseif it.total == 1 then
            total_hint = "剧场版"
        else
            total_hint = "?"
        end
        items[#items + 1] = {
            title = it.title ~= "" and it.title or ("次元城 " .. it.video_id),
            hint = (it.year > 0 and it.year or "?") .. "|" .. total_hint .. "|次元城",
            value = { "script-message-to", mp.get_script_name(), "get-cyc-event",
                it.video_id, it.title, tostring(it.year) },
        }
    end
    return items
end

-- 仅取数：搜索异步请求；callback(items, err)，返回取消函数
function fetch_cyc_search(query, callback, timeout)
    return fetch_page(SEARCH_URL .. url_encode(query) .. "&page=1&page_size=24",
        timeout or 15, function(raw)
            if not raw then
                callback(nil, "请求失败")
                return
            end
            local parsed = cparse.parse_search(raw)
            if not parsed.ok then
                callback(nil, "接口错误")
                return
            end
            callback(build_cyc_search_items(parsed.items), nil)
        end)
end

-- |cyc 搜索入口（menu.lua 按 |cyc 后缀调入）
function query_cyc_search(name)
    local menu = {
        type = "menu_anime",
        title = "在此处输入番剧名称",
        footnote = "使用enter或ctrl+enter进行搜索",
    }
    menu.cmd = { "script-message-to", mp.get_script_name(), "search-anime-event" }

    local function show(text)
        if uosc_available then
            update_menu_uosc(menu.type, menu.title, text, menu.footnote, menu.cmd, name)
        else
            show_message(text, 3)
        end
    end

    -- 英文关键词直达（english_title 参与匹配），不经 TMDB 换译名
    if uosc_available then
        update_menu_uosc(menu.type, menu.title, "加载数据中...", menu.footnote, menu.cmd, name, "spinner")
    else
        show_message("加载数据中...", 30)
    end
    fetch_cyc_search(name, function(items, err)
        if err then
            msg.error("次元城搜索失败：" .. tostring(err))
            show("无结果")
            return
        end
        if #items == 0 then
            show("无结果")
            return
        end
        if uosc_available then
            latest_menu_anime = update_menu_uosc(menu.type, menu.title, items, menu.footnote, menu.cmd, name)
        else
            show_message("", 0)
            mp.add_timeout(0.1, function()
                open_menu_select(items)
            end)
        end
    end)
end

-- ============ 菜单消息 ============

mp.register_script_message("get-cyc-event", function(video_id, title, year)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_anime")
    end

    local menu_type = "menu_details"
    local menu_title = title .. " (" .. (tonumber(year) > 0 and year or "?") .. ")"
    local footnote = "使用 / 打开筛选"
    if uosc_available then
        update_menu_uosc(menu_type, menu_title, "加载数据中...", footnote)
    else
        show_message("查询弹幕中...", 3)
    end

    fetch_cyc_sections(video_id, function(entry)
        if not entry or #entry.episodes == 0 then
            local message = "无结果"
            if uosc_available then
                update_menu_uosc(menu_type, menu_title, message, footnote)
            else
                show_message(message, 3)
            end
            return
        end

        local items = {
            {
                title = "↩️ 返回搜索结果",
                value = { "script-message-to", "uosc", "open-menu", latest_menu_anime },
                keep_open = false,
                selectable = true,
            },
        }
        for i, e in ipairs(entry.episodes) do
            local ep_title = e.title ~= "" and e.title or ("第" .. i .. "集")
            items[#items + 1] = {
                title = ep_title,
                value = { "script-message-to", mp.get_script_name(), "add-cyc-event",
                    tostring(video_id), tostring(i), title, tostring(year) },
                keep_open = true,
            }
        end
        if uosc_available then
            remember_details_menu(menu_type, menu_title, items, footnote, true)
            update_menu_uosc(menu_type, menu_title, items, footnote)
        else
            show_message("", 0)
            mp.add_timeout(0.1, function()
                open_menu_select(items)
            end)
        end
    end)
end)

mp.register_script_message("add-cyc-event", function(video_id, ep, title, year)
    load_cyc_danmaku(video_id, ep, title, year)
    mark_details_episode_added({ "script-message-to", mp.get_script_name(),
        "add-cyc-event", video_id, ep, title, year })
end)
