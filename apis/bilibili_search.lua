-- B站番剧关键词搜索流程（搜索后缀 |bili）
-- 接口：
--   api.bilibili.com/x/web-interface/wbi/search/type 搜索（WBI 签名，番剧 media_bangumi +
--   影视 media_ft 两路并发；mixinKey 来自 nav 接口、1h 缓存、失败用社区公开兜底值）→
--   api.bilibili.com/pgc/view/web/season 剧集列表（season_id → 每集 ep/cid，仅正片
--   section_type==0）→ 选集后拼 /bangumi/play/ep<id> 规范 URL 交给 add_danmaku_source
--   现有管线（extcomment → 域名直连 bilibili.com 即 sites/bilibili.lua → dmku 兜底），
--   本文件不直接取弹幕
-- 历史续载：DANMAKU.extra 记 kind="bilibili"，main.lua 的 dandanplay_flow 按 kind 分发到
--   resume_bilibili_episode

local msg = require("mp.msg")
local utils = require("mp.utils")
local bw = require("modules/bilibili_wbi")

local UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

local NAV_URL = "https://api.bilibili.com/x/web-interface/nav"
local SEARCH_URL = "https://api.bilibili.com/x/web-interface/wbi/search/type"
local SEASON_URL = "https://api.bilibili.com/pgc/view/web/season"

local SEARCH_TYPES = { "media_bangumi", "media_ft" }

-- mixinKey 缓存（nav 每次请求代价高且 key 变化频率低，1h 刷新）
local mixin_cache = { key = nil, ts = 0 }
local MIXIN_TTL = 3600

-- 构造 B站 GET 请求参数（浏览器 UA + Referer；cookie 由 cookie_file 带上，未登录也通用）
local function build_bili_args(url)
    local args = {
        'curl',
        '-L',
        '-s',
        '--compressed',
        '--user-agent',
        UA,
        '-H', 'Referer: https://www.bilibili.com/',
    }
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

-- 取 mixinKey（缓存命中直调；否则请求 nav，失败回退兜底值）；返回 nav 请求的取消函数
local function ensure_mixinkey(callback)
    if mixin_cache.key and (os.time() - mixin_cache.ts) < MIXIN_TTL then
        callback(mixin_cache.key)
        return nil
    end
    return call_cmd_async_with_timeout(build_bili_args(NAV_URL), 8, function(err, out)
        local key = nil
        if not err then
            key = bw.parse_nav(utils.parse_json(out))
        end
        if not key then
            msg.warn("B站 nav 获取失败，使用兜底 mixinKey: " .. tostring(err))
            key = bw.FALLBACK_MIXIN
        end
        mixin_cache.key = key
        mixin_cache.ts = os.time()
        callback(key)
    end)
end

-- 拉取剧集列表：season_id → 正片分集；callback(episodes)，失败传 nil
local function fetch_bili_episodes(season_id, callback)
    call_cmd_async_with_timeout(build_bili_args(SEASON_URL .. "?season_id=" .. url_encode(season_id)),
        15, function(err, out)
            if err then
                msg.warn("B站剧集列表请求失败: " .. tostring(err))
                callback(nil)
                return
            end
            local parsed = bw.parse_season(utils.parse_json(out))
            if not parsed.ok then
                msg.warn("B站剧集列表解析失败 season_id=" .. tostring(season_id)
                    .. " code=" .. tostring(parsed.code))
                callback(nil)
                return
            end
            callback(#parsed.episodes > 0 and parsed.episodes or nil)
        end)
end

-- 选集后加载（菜单选集与历史续载共用）
local function load_bilibili_danmaku(season_id, ep_id, episodenum, title, year, type_name)
    ENABLED = true
    DANMAKU.anime = title .. " (" .. year .. ")"
    DANMAKU.episode = "第" .. episodenum .. "话"
    DANMAKU.source = "bilibili"
    DANMAKU.extra = {
        kind = "bilibili",
        season_id = tostring(season_id),
        title = title,
        year = tonumber(year) or year,
        type_name = type_name,
        episodenum = tonumber(episodenum),
    }
    write_history()
    add_danmaku_source(("https://www.bilibili.com/bangumi/play/ep%s"):format(ep_id), true, "bilibili")
end

-- 历史续载入口：按 kind="bilibili" 记录推算目标集数后由 main.lua 调入
function resume_bilibili_episode(extra, episodenum)
    fetch_bili_episodes(extra.season_id, function(episodes)
        if not episodes then
            show_message("B站弹幕续载失败：无法获取剧集列表", 3)
            msg.warn("B站续载：剧集列表为空 season_id=" .. tostring(extra.season_id))
            return
        end
        local ep = episodes[episodenum]
        if not ep then
            show_message(("B站弹幕续载失败：第 %d 话不存在（共 %d 话）")
                :format(episodenum, #episodes), 3)
            return
        end
        load_bilibili_danmaku(extra.season_id, ep.ep_id, episodenum, extra.title, extra.year, extra.type_name)
    end)
end

-- 搜索解析结果 → menu_anime 条目（|bili 单源流与聚合搜索共用）
-- hint 附加 index_show（"全28话"/"更新至第195话"）与 org_title 日文原名
function build_bilibili_search_items(parsed_items)
    local items = {}
    local seen = {}
    for _, it in ipairs(parsed_items) do
        if not seen[it.season_id] then
            seen[it.season_id] = true
            local hint = it.type_name .. " | " .. it.year
            if it.index_show ~= "" then
                hint = hint .. " | " .. it.index_show
            end
            local title = it.title
            if it.org_title ~= "" and it.org_title ~= it.title then
                title = title .. " / " .. it.org_title
            end
            items[#items + 1] = {
                title = title,
                hint = hint,
                value = { "script-message-to", mp.get_script_name(), "get-bili-event",
                    it.season_id, it.title, tostring(it.year), it.type_name },
            }
        end
    end
    return items
end

-- 仅取数：双 search_type 并发聚合；callback(items, err)，返回复合取消函数
function fetch_bilibili_search(query, callback, timeout)
    local cancels = {}
    local function cancel_all()
        for _, c in ipairs(cancels) do pcall(c) end
    end
    local nav_cancel = ensure_mixinkey(function(mixin)
        local parsed_items = {}
        local pending = #SEARCH_TYPES
        local had_err = false
        local function maybe_done()
            if pending > 0 then return end
            if had_err and #parsed_items == 0 then
                callback(nil, "请求失败")
            else
                callback(build_bilibili_search_items(parsed_items), nil)
            end
        end
        for _, st in ipairs(SEARCH_TYPES) do
            local qs = bw.signed_query({
                keyword = query,
                search_type = st,
                page = "1",
            }, mixin, os.time())
            cancels[#cancels + 1] = call_cmd_async_with_timeout(
                build_bili_args(SEARCH_URL .. "?" .. qs), timeout, function(err, out)
                    pending = pending - 1
                    if err then
                        had_err = true
                    else
                        local parsed = bw.parse_search(utils.parse_json(out))
                        if parsed.ok then
                            for _, it in ipairs(parsed.items) do
                                parsed_items[#parsed_items + 1] = it
                            end
                        end
                    end
                    maybe_done()
                end)
        end
    end)
    if nav_cancel then
        cancels[#cancels + 1] = nav_cancel
    end
    return cancel_all
end

-- |bili 搜索入口（menu.lua 按 |bili 后缀调入）
function query_bilibili_search(name)
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
        fetch_bilibili_search(query, function(items, err)
            if err then
                msg.error("B站搜索失败：" .. tostring(err))
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

mp.register_script_message("get-bili-event", function(season_id, title, year, type_name)
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

    fetch_bili_episodes(season_id, function(episodes)
        if not episodes then
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
            local ep_title = "第" .. i .. "话"
            if ep.long_title ~= "" then
                ep_title = ep_title .. " " .. ep.long_title
            end
            items[#items + 1] = {
                title = ep_title,
                value = { "script-message-to", mp.get_script_name(), "add-bili-event",
                    season_id, ep.ep_id, tostring(i), title, year, type_name },
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

mp.register_script_message("add-bili-event", function(season_id, ep_id, episodenum, title, year, type_name)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_details")
    end
    load_bilibili_danmaku(season_id, ep_id, episodenum, title, year, type_name)
end)
