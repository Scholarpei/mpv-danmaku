-- 优酷关键词搜索流程（搜索后缀 |yk）
-- 接口为公开接口（无鉴权）：
--   search.youku.com/api/search 搜索（关键词 → showId，仅保留优酷版权条目）→
--   openapi.youku.com/v2/shows/videos.json 剧集列表（showId → 每集 vid，100集/页，正片 seq==stage）→
--   选集后拼规范播放页 URL 交给 add_danmaku_source 现有管线（extcomment → 域名直连 v.youku.com
--   即 sites/youku.lua → dmku 兜底），本文件不直接取弹幕
-- 历史续载：DANMAKU.extra 记 kind="youku"，main.lua 的 dandanplay_flow 按 kind 分发到 resume_youku_episode

local msg = require("mp.msg")
local utils = require("mp.utils")
local yparse = require("modules/youku_parse")

-- 优酷搜索接口要求把完整 UA 作为 userAgent 查询参数传入（实测只传部分 UA 会退化为纯 UGC 结果）
local SEARCH_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'

local SEARCH_URL = "https://search.youku.com/api/search"
local VIDEOS_URL = "https://openapi.youku.com/v2/shows/videos.json"
local CLIENT_ID = "53e6cc67237fc59a"
local PAGE_SIZE = 100
local MAX_PAGES = 10

-- 构造优酷 GET 请求参数（浏览器 UA；搜索另需 Referer/Accept）
local function build_yk_args(url, extra_headers)
    local args = {
        'curl',
        '-L',
        '-s',
        '--compressed',
        '--user-agent',
        SEARCH_UA,
    }
    for _, h in ipairs(extra_headers or {}) do
        args[#args + 1] = '-H'
        args[#args + 1] = h
    end
    if options.cookie_file and options.cookie_file ~= '' then
        args[#args + 1] = '-b'
        args[#args + 1] = mp.command_native({'expand-path', options.cookie_file})
    end
    if options.proxy ~= '' then
        args[#args + 1] = '-x'
        args[#args + 1] = options.proxy
    end
    args[#args + 1] = url
    return args
end

local function search_url(query)
    return ("%s?keyword=%s&userAgent=%s&site=1&categories=0&ftype=0&ob=0&pg=1")
        :format(SEARCH_URL, url_encode(query), url_encode(SEARCH_UA))
end

local function videos_url(show_id, page)
    return ("%s?client_id=%s&package=com.huawei.hwvplayer.youku&ext=show&show_id=%s&page=%d&count=%d")
        :format(VIDEOS_URL, CLIENT_ID, url_encode(show_id), page, PAGE_SIZE)
end

-- 拉取剧集列表：首页判定总数，>100 时并发取剩余页；stop_after 非空时集齐该数即停（续载场景）
-- callback(episodes)，首页即失败时传 nil；episodes = { {vid,title,published} }（正片序=集数编号）
local function fetch_yk_episodes(show_id, stop_after, callback)
    local function parse_page(out)
        local parsed = yparse.parse_episodes(utils.parse_json(out))
        if not parsed.ok then return nil end
        return parsed
    end

    call_cmd_async(build_yk_args(videos_url(show_id, 1)), function(err, out)
        if err then
            msg.warn("优酷剧集列表第 1 页请求失败: " .. tostring(err))
            callback(nil)
            return
        end
        local first = parse_page(out)
        if not first or #first.episodes == 0 then
            msg.warn("优酷剧集列表为空 show_id=" .. tostring(show_id))
            callback(nil)
            return
        end
        if first.total <= PAGE_SIZE or #first.episodes >= (stop_after or math.huge) then
            callback(first.episodes)
            return
        end

        -- 多页并发（parallel_requests：页码作 servers，正片判定页内完成，按页序拼接）
        local total_pages = math.min(math.ceil(first.total / PAGE_SIZE), MAX_PAGES)
        local pages = { [1] = first.episodes }
        local page_numbers = {}
        for p = 2, total_pages do
            page_numbers[#page_numbers + 1] = p
        end
        parallel_requests(page_numbers, function(page)
            return build_yk_args(videos_url(show_id, page))
        end, function(page, perr, pout)
            if perr then
                msg.warn(("优酷剧集列表第 %d 页请求失败: %s"):format(page, tostring(perr)))
            else
                local parsed = parse_page(pout)
                pages[page] = parsed and parsed.episodes or {}
            end
        end, function()
            local episodes = {}
            for p = 1, total_pages do
                for _, ep in ipairs(pages[p] or {}) do
                    episodes[#episodes + 1] = ep
                end
            end
            callback(#episodes > 0 and episodes or nil)
        end, { concurrency = 3, per_request_timeout = 15 })
    end)
end

-- 选集后加载（菜单选集与历史续载共用）
local function load_youku_danmaku(show_id, vid, episodenum, title, year, type_name)
    ENABLED = true
    DANMAKU.anime = title .. " (" .. year .. ")"
    DANMAKU.episode = "第" .. episodenum .. "集"
    DANMAKU.source = "youku"
    DANMAKU.extra = {
        kind = "youku",
        show_id = tostring(show_id),
        title = title,
        year = tonumber(year) or year,
        type_name = type_name,
        episodenum = tonumber(episodenum),
    }
    write_history()
    add_danmaku_source(("https://v.youku.com/v_show/id_%s.html"):format(vid), true, "优酷")
end

-- 历史续载入口：按 kind="youku" 记录推算目标集数后由 main.lua 调入
function resume_youku_episode(extra, episodenum)
    fetch_yk_episodes(extra.show_id, episodenum, function(episodes)
        if not episodes or #episodes == 0 then
            show_message("优酷弹幕续载失败：无法获取剧集列表", 3)
            msg.warn("优酷续载：剧集列表为空 show_id=" .. tostring(extra.show_id))
            return
        end
        local ep = episodes[episodenum]
        if not ep then
            show_message(("优酷弹幕续载失败：第 %d 集不存在（共 %d 集）")
                :format(episodenum, #episodes), 3)
            return
        end
        load_youku_danmaku(extra.show_id, ep.vid, episodenum, extra.title, extra.year, extra.type_name)
    end)
end

-- 搜索解析结果 → menu_anime 条目（|yk 单源流与聚合搜索共用）
function build_youku_search_items(parsed_items)
    local items = {}
    for _, it in ipairs(parsed_items) do
        items[#items + 1] = {
            title = it.title,
            hint = it.type_name .. " | " .. it.year,
            value = { "script-message-to", mp.get_script_name(), "get-yk-event",
                it.show_id, it.title, tostring(it.year), it.type_name },
        }
    end
    return items
end

-- 仅取数：搜索异步请求（timeout 为 nil 时不设超时，保持单源流行为）；
-- callback(items, err)，返回取消函数
function fetch_youku_search(query, callback, timeout)
    return call_cmd_async_with_timeout(build_yk_args(search_url(query), {
        'Referer: https://www.youku.com/',
        'Accept: application/json',
    }), timeout, function(err, out)
        if err then
            callback(nil, "请求失败")
            return
        end
        local parsed = yparse.parse_search(utils.parse_json(out))
        if not parsed.ok then
            callback(nil, "接口错误")
            return
        end
        callback(build_youku_search_items(parsed.items), nil)
    end)
end

-- |yk 搜索入口（menu.lua 按 |yk 后缀调入）
function query_youku_search(name)
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

    local function search(query)
        if uosc_available then
            update_menu_uosc(menu.type, menu.title, "加载数据中...", menu.footnote, menu.cmd, query, "spinner")
        else
            show_message("加载数据中...", 30)
        end
        fetch_youku_search(query, function(items, err)
            if err then
                msg.error("优酷搜索失败：" .. tostring(err))
                show("无结果")
                return
            end
            if #items == 0 then
                show("无结果")
                return
            end
            if uosc_available then
                latest_menu_anime = update_menu_uosc(menu.type, menu.title, items, menu.footnote, menu.cmd, query)
            else
                show_message("", 0)
                mp.add_timeout(0.1, function()
                    open_menu_select(items)
                end)
            end
        end)
    end

    -- 非中文关键词先经 TMDB 换中文译名；失败不阻断，用原名继续搜
    if not is_chinese(name) and type(query_tmdb) == "function"
        and options.tmdb_api_key ~= "" and #Base64.decode(options.tmdb_api_key) >= 32 then
        local title = query_tmdb(name, "tv", menu)
        if title then
            name = title
        end
    end
    search(name)
end

mp.register_script_message("get-yk-event", function(show_id, title, year, type_name)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_anime")
    end

    -- 电影直接加载第一条正片（与腾讯流程的电影捷径一致）
    if type_name == "电影" then
        show_message("查询弹幕中...", 3)
        fetch_yk_episodes(show_id, 1, function(episodes)
            if not episodes or #episodes == 0 then
                show_message("无结果", 3)
                return
            end
            load_youku_danmaku(show_id, episodes[1].vid, 1, title, year, type_name)
        end)
        return
    end

    local menu_type = "menu_details"
    local menu_title = title .. " (" .. year .. ")"
    local footnote = "使用 / 打开筛选"
    if uosc_available then
        update_menu_uosc(menu_type, menu_title, "加载数据中...", footnote)
    else
        show_message("查询弹幕中...", 3)
    end

    fetch_yk_episodes(show_id, nil, function(episodes)
        if not episodes or #episodes == 0 then
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
        for i, ep in ipairs(episodes) do
            items[#items + 1] = {
                title = yparse.format_episode_title(ep.title, i, type_name, ep.published),
                value = { "script-message-to", mp.get_script_name(), "add-yk-event",
                    show_id, ep.vid, tostring(i), title, year, type_name },
            }
        end
        if uosc_available then
            update_menu_uosc(menu_type, menu_title, items, footnote)
        else
            show_message("", 0)
            mp.add_timeout(0.1, function()
                open_menu_select(items)
            end)
        end
    end)
end)

mp.register_script_message("add-yk-event", function(show_id, vid, episodenum, title, year, type_name)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_details")
    end
    load_youku_danmaku(show_id, vid, episodenum, title, year, type_name)
end)
