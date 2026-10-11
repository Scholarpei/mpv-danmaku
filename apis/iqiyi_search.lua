-- 爱奇艺关键词搜索流程（搜索后缀 |iq）
-- 接口 mesh.if.iqiyi.com/portal/lw/search/homePageV3（无签名）：
--   搜索响应的 albumInfo 自带完整分集列表（videos[]，航海王 1180 集实测无截断，
--   number 非数字的采访/花絮剔除）——选集不再请求详情接口（www.iqiyi.com 的
--   base_info 对 Schannel TLS 指纹返回伪 invalid sign，已弃用）；
--   选集后用每集 pageUrl 原样交给 add_danmaku_source 现有管线（extcomment →
--   域名直连 iqiyi.com 即 sites/iqiyi.lua → dmku 兜底）
-- 历史续载：DANMAKU.extra 记 kind="iqiyi"，main.lua 的 dandanplay_flow 按 kind 分发；
--   分集缓存未命中（新会话）时按标题重搜一次定位

local msg = require("mp.msg")
local utils = require("mp.utils")
local iparse = require("modules/iqiyi_parse")

local UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

local SEARCH_URL = "https://mesh.if.iqiyi.com/portal/lw/search/homePageV3"

-- link_id → 分集列表缓存（会话内；选集与续载共用，miss 时重搜）
local episodes_cache = {}

-- 构造爱奇艺 GET 请求参数（浏览器 UA + Origin/Referer）
local function build_iq_args(url)
    local args = {
        'curl',
        '-L',
        '-s',
        '--ssl-no-revoke',
        '--compressed',
        '--user-agent',
        UA,
        '-H', 'Origin: https://www.iqiyi.com',
        '-H', 'Referer: https://www.iqiyi.com/',
    }
    if options.cookie_file and options.cookie_file ~= '' then
        args[#args + 1] = '-b'
        args[#args + 1] = mp.command_native({'expand-path', options.cookie_file})
    end
    if options.proxy ~= '' then
        args[#args + 1] = '-x'
        args[#args + 1] = options.proxy
    end
    append_curl_timeout(args)
    args[#args + 1] = url
    return args
end

local function search_url(query)
    return ("%s?key=%s&current_page=1&mode=1&source=input&suggest=&pageNum=1&pageSize=25&pu=&u=f6440fc5d919dca1aea12b6aff56e1c7&scale=200&token=&userVip=0&conduit=&vipType=-1&os=&osShortName=win10&dataType=&appMode=")
        :format(SEARCH_URL, url_encode(query))
end

-- 搜索原始响应 → 解析结果（顺便填充分集缓存）
local function parse_and_cache(out)
    local parsed = iparse.parse_search(utils.parse_json(out))
    if parsed.ok then
        for _, it in ipairs(parsed.items) do
            if #it.episodes > 0 then
                episodes_cache[it.link_id] = it.episodes
            end
        end
    end
    return parsed
end

-- 拉取分集列表：缓存命中直取；否则按标题重搜一次定位（续载场景）
-- callback(episodes)，失败传 nil
local function fetch_iq_episodes(link_id, title, callback)
    if episodes_cache[link_id] then
        callback(episodes_cache[link_id])
        return
    end
    if not title or title == "" then
        msg.warn("爱奇艺分集缓存未命中且无标题可重搜 link_id=" .. tostring(link_id))
        callback(nil)
        return
    end
    call_cmd_async_with_timeout(build_iq_args(search_url(title)), 15, function(err, out)
        if err then
            msg.warn("爱奇艺分集重搜失败: " .. tostring(err))
            callback(nil)
            return
        end
        local parsed = parse_and_cache(out)
        local episodes = episodes_cache[link_id]
        if not episodes then
            msg.warn("爱奇艺分集重搜未命中 link_id=" .. tostring(link_id) .. " title=" .. tostring(title))
        end
        callback(episodes)
    end)
end

-- 选集后加载（菜单选集与历史续载共用）；url 为每集 pageUrl
local function load_iqiyi_danmaku(link_id, url, episodenum, title, year, type_name)
    ENABLED = true
    DANMAKU.anime = title .. " (" .. year .. ")"
    DANMAKU.episode = "第" .. episodenum .. "集"
    DANMAKU.source = "iqiyi"
    DANMAKU.extra = {
        kind = "iqiyi",
        link_id = tostring(link_id),
        title = title,
        year = tonumber(year) or year,
        type_name = type_name,
        episodenum = tonumber(episodenum),
    }
    write_history()
    add_danmaku_source(url, true, "爱奇艺",
        {anime = DANMAKU.anime, episode = DANMAKU.episode, kind = "iqiyi"})
end

-- 历史续载入口：按 kind="iqiyi" 记录推算目标集数后由 main.lua 调入
function resume_iqiyi_episode(extra, episodenum)
    fetch_iq_episodes(extra.link_id, extra.title, function(episodes)
        if not episodes or #episodes == 0 then
            source_status.mark_failed("extra:iqiyi", "无法获取剧集列表", "爱奇艺弹幕续载失败")
            msg.warn("爱奇艺续载：剧集列表为空 link_id=" .. tostring(extra.link_id))
            return
        end
        local ep = episodes[episodenum]
        if not ep then
            source_status.mark_failed("extra:iqiyi",
                ("第 %d 集不存在（共 %d 集）"):format(episodenum, #episodes), "爱奇艺弹幕续载失败")
            return
        end
        load_iqiyi_danmaku(extra.link_id,
            ("https://www.iqiyi.com/v_%s.html"):format(ep.link_id), episodenum,
            extra.title, extra.year, extra.type_name)
    end)
end

-- 搜索解析结果 → menu_anime 条目（|iq 单源流与聚合搜索共用）
function build_iqiyi_search_items(parsed_items)
    local items = {}
    for _, it in ipairs(parsed_items) do
        items[#items + 1] = {
            title = it.title,
            hint = it.type_name .. " | " .. it.year,
            value = { "script-message-to", mp.get_script_name(), "get-iq-event",
                it.link_id, it.title, tostring(it.year), it.type_name },
        }
    end
    return items
end

-- 仅取数：搜索异步请求；callback(items, err)，返回取消函数
function fetch_iqiyi_search(query, callback, timeout)
    return call_cmd_async_with_timeout(build_iq_args(search_url(query)), timeout, function(err, out)
        if err then
            callback(nil, "请求失败")
            return
        end
        local parsed = parse_and_cache(out)
        if not parsed.ok then
            callback(nil, "接口错误")
            return
        end
        callback(build_iqiyi_search_items(parsed.items), nil)
    end)
end

-- |iq 搜索入口（menu.lua 按 |iq 后缀调入）
function query_iqiyi_search(name)
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
        fetch_iqiyi_search(query, function(items, err)
            if err then
                msg.error("爱奇艺搜索失败：" .. tostring(err))
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

    -- 非中文关键词先经 TMDB 换中文译名；失败不阻断
    if not is_chinese(name) and type(query_tmdb) == "function"
        and options.tmdb_api_key ~= "" and #Base64.decode(options.tmdb_api_key) >= 32 then
        local title = query_tmdb(name, "tv", menu)
        if title then
            name = title
        end
    end
    search(name)
end

mp.register_script_message("get-iq-event", function(link_id, title, year, type_name)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_anime")
    end

    local menu_type = "menu_details"
    local menu_title = title .. " (" .. year .. ")"
    local footnote = "使用 / 打开筛选"
    if uosc_available then
        update_menu_uosc(menu_type, menu_title, "加载数据中...", footnote)
    else
        show_message("查询弹幕中...", 3)
    end

    -- 分集来自搜索时的缓存（一般已命中）；miss 则按标题重搜
    fetch_iq_episodes(link_id, title, function(episodes)
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
            -- 标题形如「狂飙第1集」，直接展示（集数序 = 列表序）
            items[#items + 1] = {
                title = ep.title ~= "" and ep.title or ("第" .. i .. "集"),
                value = { "script-message-to", mp.get_script_name(), "add-iq-event",
                    link_id, ep.link_id, tostring(i), title, year, type_name },
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

mp.register_script_message("add-iq-event", function(link_id, ep_link_id, episodenum, title, year, type_name)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_details")
    end
    load_iqiyi_danmaku(link_id,
        ("https://www.iqiyi.com/v_%s.html"):format(ep_link_id), episodenum,
        title, year, type_name)
end)
