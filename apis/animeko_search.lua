-- animeko（open-ani 社区番剧弹幕）关键词搜索流程（搜索后缀 |ako）
-- 接口均为公开接口：
--   api.bgm.tv/v0/search/subjects 搜索（Bangumi 元数据，UA 需自识别）→
--   <node>/v2/subjects/<subjectId> 剧集列表（episodeId，仅 MAIN 正片，节点降级）→
--   选集后拼 https://api.animeko.org/episode/<episodeId> 规范 URL 交给
--   add_danmaku_source 现有管线（extcomment 尝试会无害失败 → 域名直连 sites/animeko.lua）
-- 历史续载：DANMAKU.extra 记 kind="animeko"，main.lua 的 dandanplay_flow 按 kind 分发

local msg = require("mp.msg")
local utils = require("mp.utils")
local aparse = require("modules/animeko_parse")

-- 节点顺序与 sites/animeko.lua 一致
local NODES = {
    "https://api.animeko.org",
    "https://danmaku-global.myani.org",
    "https://danmaku-cn.myani.org",
    "https://s1.animeko.openani.org",
}

-- bgm.tv 社区礼仪：请求需携带自识别 UA
local BGM_UA = 'uosc-danmaku/1.0 (https://github.com/Scholarpei/uosc_danmaku)'

local BGM_HOSTS = { "https://api.bgm.tv", "https://api.bangumi.vip" }

local function build_args(url, ua, method, body)
    local args = {
        'curl',
        '-L',
        '-s',
        '--compressed',
        '--user-agent',
        ua,
    }
    if method == "POST" then
        args[#args + 1] = '-X'
        args[#args + 1] = 'POST'
        args[#args + 1] = '-H'
        args[#args + 1] = 'Content-Type: application/json'
        args[#args + 1] = '-d'
        args[#args + 1] = utils.format_json(body)
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

-- bgm.tv 搜索（主站失败切镜像）
local function fetch_bgm_search(query, callback, timeout)
    local host_idx = 1
    local function try_host()
        if host_idx > #BGM_HOSTS then
            callback(nil, "请求失败")
            return
        end
        local host = BGM_HOSTS[host_idx]
        host_idx = host_idx + 1
        call_cmd_async_with_timeout(build_args(
            host .. "/v0/search/subjects?limit=20&offset=0", BGM_UA, "POST", {
                keyword = query,
                filter = { type = { 2 } },
            }), timeout, function(err, out)
            if err or not out or out == '' then
                msg.warn("bgm 搜索失败 " .. host .. ": " .. tostring(err))
                try_host()
                return
            end
            callback(out, nil)
        end)
    end
    try_host()
end

-- v2/subjects 剧集列表（节点依次降级）
local function fetch_ako_episodes(subject_id, callback)
    local node_idx = 1
    local function try_node()
        if node_idx > #NODES then
            msg.warn("animeko 分集全部节点尝试失败 subject_id=" .. tostring(subject_id))
            callback(nil)
            return
        end
        local node = NODES[node_idx]
        node_idx = node_idx + 1
        call_cmd_async_with_timeout(build_args(
            node .. "/v2/subjects/" .. tostring(subject_id), BGM_UA), 15,
            function(err, out)
                if err or not out or out == '' then
                    msg.warn("animeko 分集节点失败 " .. node .. ": " .. tostring(err))
                    try_node()
                    return
                end
                local parsed = aparse.parse_subject(utils.parse_json(out))
                if not parsed.ok or #parsed.episodes == 0 then
                    msg.warn("animeko 分集解析为空 subject_id=" .. tostring(subject_id))
                    callback(nil)
                    return
                end
                callback(parsed.episodes)
            end)
    end
    try_node()
end

-- 选集后加载（菜单选集与历史续载共用）
local function load_animeko_danmaku(subject_id, episode_id, episodenum, title, year)
    ENABLED = true
    DANMAKU.anime = title .. " (" .. year .. ")"
    DANMAKU.episode = "第" .. episodenum .. "话"
    DANMAKU.source = "animeko"
    DANMAKU.extra = {
        kind = "animeko",
        subject_id = tostring(subject_id),
        title = title,
        year = tonumber(year) or year,
        episodenum = tonumber(episodenum),
    }
    write_history()
    add_danmaku_source(("https://api.animeko.org/episode/%s"):format(episode_id), true, "animeko")
end

-- 历史续载入口：按 kind="animeko" 记录推算目标集数后由 main.lua 调入
function resume_animeko_episode(extra, episodenum)
    fetch_ako_episodes(extra.subject_id, function(episodes)
        if not episodes then
            show_message("animeko 弹幕续载失败：无法获取剧集列表", 3)
            msg.warn("animeko 续载：剧集列表为空 subject_id=" .. tostring(extra.subject_id))
            return
        end
        local ep = episodes[episodenum]
        if not ep then
            show_message(("animeko 弹幕续载失败：第 %d 话不存在（共 %d 话）")
                :format(episodenum, #episodes), 3)
            return
        end
        load_animeko_danmaku(extra.subject_id, ep.episode_id, episodenum, extra.title, extra.year)
    end)
end

-- 搜索原始响应文本 → menu_anime 条目
function build_animeko_search_items(out)
    local parsed = aparse.parse_search(utils.parse_json(out))
    if not parsed.ok then return {} end
    local items = {}
    for _, it in ipairs(parsed.items) do
        items[#items + 1] = {
            title = it.title,
            hint = "番剧 | " .. it.year,
            value = { "script-message-to", mp.get_script_name(), "get-ako-event",
                it.subject_id, it.title, tostring(it.year) },
        }
    end
    return items
end

-- 仅取数：搜索异步请求；callback(items, err)，返回取消函数（内部降级重试链的取消由超时兜底）
function fetch_animeko_search(query, callback, timeout)
    -- fetch_bgm_search 自带降级链，这里只包一层取消（首个请求由其内部管理）
    local dummy_cancel = function() end
    fetch_bgm_search(query, function(out, err)
        if err then
            callback(nil, err)
            return
        end
        callback(build_animeko_search_items(out), nil)
    end, timeout)
    return dummy_cancel
end

-- |ako 搜索入口（menu.lua 按 |ako 后缀调入）
function query_animeko_search(name)
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
        fetch_animeko_search(query, function(items, err)
            if err then
                msg.error("animeko 搜索失败：" .. tostring(err))
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

    -- 非中文关键词先经 TMDB 换中文/日文译名（bgm 搜索对原文名命中更好）；失败不阻断
    if not is_chinese(name) and type(query_tmdb) == "function"
        and options.tmdb_api_key ~= "" and #Base64.decode(options.tmdb_api_key) >= 32 then
        local title = query_tmdb(name, "tv", menu)
        if title then
            name = title
        end
    end
    search(name)
end

mp.register_script_message("get-ako-event", function(subject_id, title, year)
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

    fetch_ako_episodes(subject_id, function(episodes)
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
            if ep.title ~= "" then
                ep_title = ep_title .. " " .. ep.title
            end
            items[#items + 1] = {
                title = ep_title,
                value = { "script-message-to", mp.get_script_name(), "add-ako-event",
                    subject_id, ep.episode_id, tostring(i), title, year },
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

mp.register_script_message("add-ako-event", function(subject_id, episode_id, episodenum, title, year)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_details")
    end
    load_animeko_danmaku(subject_id, episode_id, episodenum, title, year)
end)
