-- MacCMS（苹果CMS）采集站搜索流程（搜索后缀 |mac）
-- 流程：并发搜索所有已配置采集站（options.maccms_servers，标准接口 /api.php/provide/vod/）→
--   结果菜单（标注年份/分类/站点）→ 多播放来源组时先选来源 → 剧集菜单 → 选集后把播放页 URL
--   交给 add_danmaku_source 现有管线（extcomment → 域名直连站 → dmku/danmu.icu 兜底），
--   本文件不直接取弹幕
-- 历史续载：DANMAKU.extra 记 kind="maccms"（含 server/vod_id/group），换集时按 id 重取详情
--   定位目标集（main.lua 的 dandanplay_flow 按 kind 分发到 resume_maccms_episode）

local msg = require("mp.msg")
local utils = require("mp.utils")
local mparse = require("modules/maccms_parse")

-- server .. "|" .. vod_id → { server, vod_id, vod_name, vod_year, vod_class, play }
-- （照 extra.lua cached_series_playlinks 的会话级缓存模式，菜单消息只传短参数）
local cached_vod = {}

local function cache_key(server, vod_id)
    return tostring(server) .. "|" .. tostring(vod_id)
end

-- 采集站根地址 → 菜单标注用的 host（去 www. 前缀）
local function host_label(server)
    local host = tostring(server):match("^https?://([^/]+)")
    if not host then return tostring(server) end
    return host:gsub("^www%.", "")
end

-- 构造采集接口 URL：{根地址}/api.php/provide/vod/?ac=detail&wd=...（或 &ids=...）
local function vod_request_url(server, params)
    local base = tostring(server):gsub("/+$", "")
    local query = {}
    for _, k in ipairs({ "ac", "wd", "ids" }) do
        local v = params[k]
        if v ~= nil then
            query[#query + 1] = k .. "=" .. url_encode(tostring(v))
        end
    end
    return base .. "/api.php/provide/vod/?" .. table.concat(query, "&")
end

-- 原始 vod 条目 → 缓存条目（解析播放来源组；remarks 如「全24集」供搜索菜单标注）
local function cache_vod(server, raw)
    local entry = {
        server = server,
        vod_id = tonumber(raw.vod_id) or raw.vod_id,
        vod_name = tostring(raw.vod_name or ""),
        vod_year = tonumber(raw.vod_year) or 0,
        vod_class = type(raw.vod_class) == "string" and raw.vod_class or "",
        remarks = raw.vod_remarks ~= nil and tostring(raw.vod_remarks) or "",
        play = mparse.parse_play_sources(raw),
    }
    cached_vod[cache_key(server, entry.vod_id)] = entry
    return entry
end

-- 按 id 重取详情（缓存命中不发网络）；callback(entry) 或 callback(nil)
local function fetch_vod_by_id(server, vod_id, callback)
    local key = cache_key(server, vod_id)
    if cached_vod[key] then
        callback(cached_vod[key])
        return
    end
    local args = make_danmaku_request_args("GET",
        vod_request_url(server, { ac = "detail", ids = tostring(vod_id) }))
    if not args then
        callback(nil)
        return
    end
    call_cmd_async(args, function(err, out)
        if err then
            msg.warn(("采集站详情请求失败 %s: %s"):format(tostring(server), tostring(err)))
            callback(nil)
            return
        end
        local d = utils.parse_json(out)
        for _, raw in ipairs(mparse.get_raw_list(d) or {}) do
            if type(raw) == "table" then
                local rid = raw.vod_id ~= nil and tostring(tonumber(raw.vod_id) or raw.vod_id) or nil
                if rid == tostring(vod_id) then
                    callback(cache_vod(server, raw))
                    return
                end
            end
        end
        msg.warn("采集站详情无对应条目 " .. tostring(server) .. " id=" .. tostring(vod_id))
        callback(nil)
    end)
end

-- 选集后加载（菜单选集与历史续载共用；title/year 可覆盖缓存值供续载保持记录稳定）
local function load_maccms_danmaku(server, vod_id, group_idx, ep_idx, title, year)
    local entry = cached_vod[cache_key(server, vod_id)]
    local ep = entry and mparse.get_episode(entry.play, group_idx, ep_idx)
    if not ep then
        show_message("采集站剧集信息缺失", 3)
        return
    end
    local display_title = title or (entry.vod_name ~= "" and entry.vod_name or tostring(vod_id))
    local display_year = year or entry.vod_year
    ENABLED = true
    DANMAKU.anime = display_title .. " (" .. (tonumber(display_year) or 0) .. ")"
    DANMAKU.episode = "第" .. ep_idx .. "集"
    DANMAKU.source = "maccms"
    DANMAKU.extra = {
        kind = "maccms",
        server = tostring(server),
        vod_id = tostring(vod_id),
        group = tonumber(group_idx),
        title = display_title,
        year = tonumber(display_year) or 0,
        episodenum = tonumber(ep_idx),
    }
    write_history()
    add_danmaku_source(ep.url, true, "maccms·" .. host_label(server))
end

-- 历史续载入口：按 kind="maccms" 记录推算目标集数后由 main.lua 调入
function resume_maccms_episode(extra, episodenum)
    fetch_vod_by_id(extra.server, extra.vod_id, function(entry)
        if not entry then
            show_message("采集站弹幕续载失败：无法获取剧集列表", 3)
            msg.warn("采集站续载：详情获取失败 " .. tostring(extra.server) .. " id=" .. tostring(extra.vod_id))
            return
        end
        local group = tonumber(extra.group) or 1
        if not mparse.get_episode(entry.play, group, episodenum) then
            show_message(("采集站弹幕续载失败：第 %d 集不存在"):format(episodenum), 3)
            return
        end
        load_maccms_danmaku(extra.server, extra.vod_id, group, episodenum, extra.title, extra.year)
    end)
end

-- 剧集菜单（单播放组直接进入；多组先经 get-maccms-event 的「播放来源」菜单）
local function show_episode_menu(server, vod_id, group_idx)
    local entry = cached_vod[cache_key(server, vod_id)]
    local play = entry and entry.play or nil
    if not play or not play.urls[group_idx] then
        show_message("无结果", 3)
        return
    end
    local menu_type = "menu_details"
    local menu_title = entry.vod_name .. " (" .. (entry.vod_year > 0 and entry.vod_year or "?") .. ")"
    local footnote = "使用 / 打开筛选"

    local items = {
        {
            title = "↩️ 返回搜索结果",
            value = { "script-message-to", "uosc", "open-menu", latest_menu_anime },
            keep_open = false,
            selectable = true,
        },
    }
    for i, ep in ipairs(play.urls[group_idx]) do
        items[#items + 1] = {
            title = "第" .. i .. "集",
            hint = ep.title ~= "" and ep.title ~= tostring(i) and ep.title or nil,
            value = { "script-message-to", mp.get_script_name(), "add-maccms-event",
                tostring(server), tostring(vod_id), tostring(group_idx), tostring(i) },
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
end

-- 搜索命中列表 → menu_anime 条目（hint: 年份|分类|站点[|备注]；found 按站点配置顺序排好）
function build_maccms_items(found)
    local items = {}
    for _, it in ipairs(found) do
        local e = it.entry
        local parts = {}
        parts[#parts + 1] = e.vod_year > 0 and tostring(e.vod_year) or "?"
        if e.vod_class ~= "" then
            parts[#parts + 1] = e.vod_class
        end
        parts[#parts + 1] = host_label(it.server)
        if e.remarks ~= "" then
            parts[#parts + 1] = e.remarks
        end
        items[#items + 1] = {
            title = e.vod_name,
            hint = table.concat(parts, "|"),
            value = { "script-message-to", mp.get_script_name(), "get-maccms-event",
                tostring(it.server), tostring(e.vod_id) },
        }
    end
    return items
end

-- 仅取数：并发搜索全部采集站（单站失败不影响其它站，结果按配置顺序稳定）；
-- callback(found, all_failed)——all_failed=全部站点请求失败（区别于「搜不到」）；返回取消函数。
-- opts: { concurrency=3, per_request_timeout=15 }（聚合搜索传更紧的超时）
function fetch_maccms_found(name, callback, opts)
    opts = opts or {}
    local servers = get_api_server_list(options.maccms_servers)
    local server_order = {}
    for i, s in ipairs(servers) do server_order[s] = i end
    local found = {}
    local err_count = 0

    local function build_args(server)
        -- wd 由 vod_request_url 内统一 url_encode，此处传原文防双重编码
        return make_danmaku_request_args("GET",
            vod_request_url(server, { ac = "detail", wd = name }))
    end

    local function per_response(server, err, out)
        if err then
            err_count = err_count + 1
            msg.warn(("采集站搜索失败 %s: %s"):format(tostring(server), tostring(err)))
            return
        end
        local d = utils.parse_json(out)
        if type(d) ~= "table" then return end
        for _, raw in ipairs(mparse.get_raw_list(d) or {}) do
            if type(raw) == "table" and raw.vod_id ~= nil then
                local entry = cache_vod(server, raw)
                if entry.vod_name ~= "" and #entry.play.from > 0 then
                    found[#found + 1] = { server = server, entry = entry }
                end
            end
        end
    end

    return parallel_requests(servers, build_args, per_response, function()
        table.sort(found, function(a, b)
            return server_order[a.server] < server_order[b.server]
        end)
        callback(found, #servers > 0 and err_count == #servers)
    end, { concurrency = opts.concurrency or 3, per_request_timeout = opts.per_request_timeout or 15 })
end

-- |mac 搜索入口（menu.lua 按 |mac 后缀调入）
function query_maccms_search(name)
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

    local servers = get_api_server_list(options.maccms_servers)
    if #servers == 0 then
        show("未配置采集站地址：请在 script-opts 中设置 maccms_servers（站点根地址，逗号分隔）")
        return
    end

    -- 非中文关键词先经 TMDB 换中文译名（复用 360kan 流程的 query_tmdb）；失败不阻断用原名继续搜
    if not is_chinese(name) and type(query_tmdb) == "function"
        and options.tmdb_api_key ~= "" and #Base64.decode(options.tmdb_api_key) >= 32 then
        local title = query_tmdb(name, "tv", menu)
        if title then
            name = title
        end
    end

    if uosc_available then
        update_menu_uosc(menu.type, menu.title, "加载数据中...", menu.footnote, menu.cmd, name, "spinner")
    else
        show_message("加载数据中...", 30)
    end

    -- 并发搜索全部采集站（fetch_maccms_found），单站失败不影响其它站
    fetch_maccms_found(name, function(found, all_failed)
        if all_failed or #found == 0 then
            show("无结果")
            return
        end
        local items = build_maccms_items(found)
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

mp.register_script_message("get-maccms-event", function(server, vod_id)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_anime")
    end
    fetch_vod_by_id(server, vod_id, function(entry)
        if not entry or #entry.play.from == 0 then
            show_message("无结果", 3)
            return
        end
        if #entry.play.from == 1 then
            show_episode_menu(server, vod_id, 1)
            return
        end
        -- 多播放来源组：先选来源（不同组的集数划分可能不同）
        local items = {
            {
                title = "↩️ 返回搜索结果",
                value = { "script-message-to", "uosc", "open-menu", latest_menu_anime },
                keep_open = false,
                selectable = true,
            },
        }
        for gi, gname in ipairs(entry.play.from) do
            items[#items + 1] = {
                title = gname,
                hint = #entry.play.urls[gi] .. "集",
                value = { "script-message-to", mp.get_script_name(), "maccms-group-event",
                    tostring(server), tostring(vod_id), tostring(gi) },
            }
        end
        if uosc_available then
            update_menu_uosc("menu_details", "播放来源", items, "使用 / 打开筛选")
        else
            show_message("", 0)
            mp.add_timeout(0.1, function()
                open_menu_select(items)
            end)
        end
    end)
end)

mp.register_script_message("maccms-group-event", function(server, vod_id, group_idx)
    show_episode_menu(server, vod_id, tonumber(group_idx))
end)

mp.register_script_message("add-maccms-event", function(server, vod_id, group_idx, ep_idx)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_details")
    end
    load_maccms_danmaku(server, vod_id, tonumber(group_idx), tonumber(ep_idx))
end)
