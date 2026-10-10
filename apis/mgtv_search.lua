-- 芒果TV关键词搜索流程（搜索后缀 |mg）
-- 接口为公开接口：
--   mobileso.bz.mgtv.com/aphone/search/rebirth/v2 搜索（安卓 UA + md5 设备标识，仅保留芒果版权条目）→
--   pcweb.api.mgtv.com/variety/showlist 剧集列表（clipId → 每集 video_id，综艺按月分页并发）→
--   选集后拼规范播放页 URL 交给 add_danmaku_source 现有管线（extcomment → 域名直连 mgtv.com
--   即 sites/mgtv.lua → dmku 兜底），本文件不直接取弹幕
-- 历史续载：DANMAKU.extra 记 kind="mgtv"，main.lua 的 dandanplay_flow 按 kind 分发到 resume_mgtv_episode

local msg = require("mp.msg")
local utils = require("mp.utils")
local md5 = require("modules/md5")
local gparse = require("modules/mgtv_parse")

local SEARCH_UA = 'Dalvik/2.1.0 (Linux; U; Android 16; MI 23127PN0CC)'
local WEB_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

local SEARCH_URL = "https://mobileso.bz.mgtv.com/aphone/search/rebirth/v2"
local SHOWLIST_URL = "https://pcweb.api.mgtv.com/variety/showlist"

-- 设备标识：did 会话内稳定（接口可能按设备风控，频繁更换反而异常），seqId 每请求新生成
local session_did = nil
local function get_did()
    if not session_did then
        session_did = md5.sum("uosc-danmaku-mgtv-" .. tostring(os.time()))
    end
    return session_did
end

-- 构造芒果 GET 请求参数（安卓/网页两种 UA）
local function build_mg_args(url, ua, extra_headers)
    local args = {
        'curl',
        '-L',
        '-s',
        '--compressed',
        '--user-agent',
        ua,
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
    local did = get_did()
    local ms = tostring(os.time()) .. string.format("%03d", math.random(0, 999))
    local seq = md5.sum(did .. "." .. ms)
    return ("%s?q=%s&_support=10100001&device=23127PN0CC&osVersion=16&appVersion=9.3.3&did=%s&mac=%s&seqId=%s&ticket=&userId=0&osType=android&type=10&abroad=0")
        :format(SEARCH_URL, url_encode(query), did, did, seq)
end

local function showlist_url(collection_id, month)
    return ("%s?allowedRC=1&collection_id=%s&month=%s&page=1&_support=10000000")
        :format(SHOWLIST_URL, url_encode(collection_id), month or "")
end

-- 拉取剧集列表：首请求（month 空）读 tab_m 月份表，综艺按月并发补拉；
-- stop_after 非空时集齐该数即停（续载场景）。callback(episodes)，首请求失败时传 nil
local function fetch_mg_episodes(collection_id, stop_after, callback)
    call_cmd_async(build_mg_args(showlist_url(collection_id, ""), WEB_UA, {
        'Referer: https://www.mgtv.com/',
    }), function(err, out)
        if err then
            msg.warn("芒果剧集列表请求失败: " .. tostring(err))
            callback(nil)
            return
        end
        local first = gparse.parse_showlist(utils.parse_json(out), collection_id)
        if not first.ok then
            msg.warn("芒果剧集列表解析失败 collection_id=" .. tostring(collection_id))
            callback(nil)
            return
        end
        if #first.episodes == 0 and #first.months == 0 then
            callback(nil)
            return
        end

        -- 电视剧：单月即全集；综艺：tab_m 倒序 → 翻正序逐月拉取
        local months = {}
        for i = #first.months, 1, -1 do
            months[#months + 1] = first.months[i]
        end
        if stop_after ~= nil and #first.episodes >= stop_after then
            months = {}
        end

        if #months == 0 then
            callback(gparse.merge_month_episodes({ first.episodes }))
            return
        end

        local month_eps = { [""] = first.episodes }
        local month_keys = { "" }
        for _, m in ipairs(months) do
            month_keys[#month_keys + 1] = m
        end
        parallel_requests(month_keys, function(m)
            if m == "" then return nil end -- 首月已取
            return build_mg_args(showlist_url(collection_id, m), WEB_UA, {
                'Referer: https://www.mgtv.com/',
            })
        end, function(m, merr, mout)
            if m == "" then return end
            if merr then
                msg.warn("芒果分集月份 " .. tostring(m) .. " 请求失败: " .. tostring(merr))
            else
                local parsed = gparse.parse_showlist(utils.parse_json(mout), collection_id)
                month_eps[m] = parsed.episodes
            end
        end, function()
            local ordered = {}
            for _, m in ipairs(month_keys) do
                ordered[#ordered + 1] = month_eps[m] or {}
            end
            local merged = gparse.merge_month_episodes(ordered)
            callback(#merged > 0 and merged or nil)
        end, { concurrency = 3, per_request_timeout = 15 })
    end)
end

-- 选集后加载（菜单选集与历史续载共用）
local function load_mgtv_danmaku(collection_id, video_id, episodenum, title, year, type_name)
    ENABLED = true
    DANMAKU.anime = title .. " (" .. year .. ")"
    DANMAKU.episode = "第" .. episodenum .. "集"
    DANMAKU.source = "mgtv"
    DANMAKU.extra = {
        kind = "mgtv",
        collection_id = tostring(collection_id),
        title = title,
        year = tonumber(year) or year,
        type_name = type_name,
        episodenum = tonumber(episodenum),
    }
    write_history()
    add_danmaku_source(("https://www.mgtv.com/b/%s/%s.html"):format(collection_id, video_id), true, "芒果TV")
end

-- 历史续载入口：按 kind="mgtv" 记录推算目标集数后由 main.lua 调入
function resume_mgtv_episode(extra, episodenum)
    fetch_mg_episodes(extra.collection_id, episodenum, function(episodes)
        if not episodes or #episodes == 0 then
            show_message("芒果弹幕续载失败：无法获取剧集列表", 3)
            msg.warn("芒果续载：剧集列表为空 collection_id=" .. tostring(extra.collection_id))
            return
        end
        local ep = episodes[episodenum]
        if not ep then
            show_message(("芒果弹幕续载失败：第 %d 集不存在（共 %d 集）")
                :format(episodenum, #episodes), 3)
            return
        end
        load_mgtv_danmaku(extra.collection_id, ep.video_id, episodenum, extra.title, extra.year, extra.type_name)
    end)
end

-- 搜索解析结果 → menu_anime 条目（|mg 单源流与聚合搜索共用）
function build_mgtv_search_items(parsed_items)
    local items = {}
    for _, it in ipairs(parsed_items) do
        items[#items + 1] = {
            title = it.title,
            hint = it.type_name .. " | " .. it.year,
            value = { "script-message-to", mp.get_script_name(), "get-mg-event",
                it.clip_id, it.title, tostring(it.year), it.type_name },
        }
    end
    return items
end

-- 仅取数：搜索异步请求；callback(items, err)，返回取消函数
function fetch_mgtv_search(query, callback, timeout)
    return call_cmd_async_with_timeout(build_mg_args(search_url(query), SEARCH_UA), timeout, function(err, out)
        if err then
            callback(nil, "请求失败")
            return
        end
        local parsed = gparse.parse_search(utils.parse_json(out))
        if not parsed.ok then
            callback(nil, "接口错误")
            return
        end
        callback(build_mgtv_search_items(parsed.items), nil)
    end)
end

-- |mg 搜索入口（menu.lua 按 |mg 后缀调入）
function query_mgtv_search(name)
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
        fetch_mgtv_search(query, function(items, err)
            if err then
                msg.error("芒果搜索失败：" .. tostring(err))
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

mp.register_script_message("get-mg-event", function(clip_id, title, year, type_name)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_anime")
    end

    -- 电影直接加载第一条正片（与腾讯流程的电影捷径一致）
    if type_name == "电影" then
        show_message("查询弹幕中...", 3)
        fetch_mg_episodes(clip_id, 1, function(episodes)
            if not episodes or #episodes == 0 then
                show_message("无结果", 3)
                return
            end
            load_mgtv_danmaku(clip_id, episodes[1].video_id, 1, title, year, type_name)
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

    fetch_mg_episodes(clip_id, nil, function(episodes)
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
                title = ep.title,
                value = { "script-message-to", mp.get_script_name(), "add-mg-event",
                    clip_id, ep.video_id, tostring(i), title, year, type_name },
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

mp.register_script_message("add-mg-event", function(clip_id, video_id, episodenum, title, year, type_name)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_details")
    end
    load_mgtv_danmaku(clip_id, video_id, episodenum, title, year, type_name)
end)
