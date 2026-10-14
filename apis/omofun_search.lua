-- OmoFun（Lanerc）关键词搜索流程（搜索后缀 |omf）
-- 接口（App API 逆向链路，签名/解密与响应形态见 modules/omofun_parse.lua；签名
--   客户端与域名发现在 sites/omofun.lua——本文件 require 之共用内存状态）：
--   GET app/vod/search?keyword=<关键词>（⚠️ 参数名 keyword，wd= 报 400）→ 条目
--   {id, vod_name, vod_year, vod_total, vod_isend, vod_class}（多季番独立条目）→
--   选条目后经 fetch_omofun_detail 拉详情选集（会话级缓存）渲染选集菜单 →
--   选集后拼 https://lanerc.life/vod/{vod_id}/{集序号} 规范 URL 交给
--   add_danmaku_source 现有管线（lanerc.life 域名跳过 extcomment 直连
--   sites/omofun.lua；URL 为固定标识域，与运行时发现的实际 API 域名解耦）
-- 历史续载：DANMAKU.extra 记 kind="omf"（含 vod_id/title/year），换集时重取详情
--   按集序号定位目标集 resource_id（会话缓存命中零网络），main.lua 的
--   dandanplay_flow 按 kind 分发
-- 非中文关键词先经 TMDB 换中文译名（后端为中文站，英文直达不可期；失败不阻断）

local msg = require("mp.msg")
local utils = require("mp.utils")
local oparse = require("modules/omofun_parse")
require("sites/omofun")  -- 签名客户端（omf_signed_get / fetch_omofun_detail；共用域名/游客态缓存）

local SEARCH_PATH = "app/vod/search"
local PLAY_BASE = "https://lanerc.life/vod/"

-- ============ 选集后加载（菜单选集与历史续载共用） ============

-- 集标题（详情 name/title）→ 菜单与 OSD 展示：纯数字规整为「第N集」（去前导零），
-- 非数字（剧场版名等）原样展示，缺失回退序号
local function episode_label(ep_title, episodenum)
    if type(ep_title) == "string" and ep_title ~= "" then
        if ep_title:match("^%d+$") then
            return "第" .. tostring(tonumber(ep_title)) .. "集"
        end
        return ep_title
    end
    return "第" .. episodenum .. "集"
end

local function load_omofun_danmaku(vod_id, ep, title, year, ep_title)
    ENABLED = true
    DANMAKU.anime = title .. " (" .. (tonumber(year) > 0 and year or 0) .. ")"
    DANMAKU.episode = episode_label(ep_title, ep)
    DANMAKU.source = "omf"
    DANMAKU.extra = {
        kind = "omf",
        vod_id = tostring(vod_id),
        title = title,
        year = tonumber(year) or 0,
        episodenum = tonumber(ep) or 1,
    }
    write_history()
    -- 同源单选收紧：驱逐 OmoFun 旧集源（标记层 exclusive 同步，见 add-omf-event）
    local src_url = PLAY_BASE .. vod_id .. "/" .. ep
    remove_same_provider_sources("OmoFun", src_url)
    add_danmaku_source(src_url, true, "OmoFun",
        { anime = DANMAKU.anime, episode = DANMAKU.episode, kind = "omf" })
end

-- 历史续载入口：按 kind="omf" 记录重取详情、按集序号定位目标集，由 main.lua 调入；
-- 超出集数按失败上报不静默（不消费过期缓存，同 cyc 口径）
function resume_omofun_episode(extra, episodenum)
    fetch_omofun_detail(extra.vod_id, function(entry)
        if not entry then
            source_status.mark_failed("extra:omf", "无法获取选集列表", "OmoFun弹幕续载失败")
            return
        end
        local target = entry.episodes[tonumber(episodenum)]
        if not target then
            source_status.mark_failed("extra:omf",
                ("第 %d 集｜共 %d 集"):format(episodenum, entry.count), "OmoFun弹幕续载失败")
            return
        end
        load_omofun_danmaku(extra.vod_id, episodenum, extra.title, extra.year, target.title)
    end)
end

-- 下一集预取：目标集数 → 对应 vid → 拉弹幕写 omf: 磁盘缓存（sites/omofun.lua；
-- 仅取详情与弹幕，无 OSD/history/sources 副作用，与 resume 路径同源）
function prefetch_omofun_episode(extra, episodenum, callback)
    callback = callback or function() end
    fetch_omofun_detail(extra.vod_id, function(entry)
        local target = entry and entry.episodes[tonumber(episodenum)] or nil
        if not target then
            callback(false)
            return
        end
        prefetch_omofun_danmaku(extra.vod_id, episodenum, callback)
    end)
end

-- ============ 搜索 ============

-- 搜索解析结果 → menu_anime 条目（|omf 单源流与聚合搜索共用）；
-- hint 标注 年份|完结状态|站点（vod_isend 1=完结；多集连载显示总集数，单集条目
-- 标剧场版——不强制过滤由用户自挑）
function build_omofun_search_items(parsed_items)
    local items = {}
    for _, it in ipairs(parsed_items) do
        local total_hint
        if it.total > 1 then
            total_hint = it.is_end == 1 and "完结" or it.total .. "集"
        elseif it.total == 1 then
            total_hint = "剧场版"
        else
            total_hint = "?"
        end
        items[#items + 1] = {
            title = it.title,
            hint = (it.year > 0 and it.year or "?") .. "|" .. total_hint .. "|OmoFun",
            value = { "script-message-to", mp.get_script_name(), "get-omf-event",
                it.vod_id, it.title, tostring(it.year) },
        }
    end
    return items
end

-- 仅取数：搜索异步请求；callback(items, err)，返回取消函数
function fetch_omofun_search(query, callback, timeout)
    return omf_signed_get(SEARCH_PATH, { { "keyword", query } }, function(d)
        if d == nil then
            callback(nil, "请求失败")
            return
        end
        local parsed = oparse.parse_search(d)
        if not parsed.ok then
            callback(nil, "接口错误")
            return
        end
        callback(build_omofun_search_items(parsed.items), nil)
    end, timeout or 15)
end

-- |omf 搜索入口（menu.lua 按 |omf 后缀调入）
function query_omofun_search(name)
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
        fetch_omofun_search(query, function(items, err)
            if err then
                msg.error("OmoFun 搜索失败：" .. tostring(err))
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

    -- 非中文关键词先经 TMDB 换中文译名（后端中文站，英文直达不可期）；失败不阻断
    if not is_chinese(name) and type(query_tmdb) == "function"
        and options.tmdb_api_key ~= "" and #Base64.decode(options.tmdb_api_key) >= 32 then
        local title = query_tmdb(name, "tv", menu)
        if title then
            name = title
        end
    end
    search(name)
end

-- ============ 菜单消息 ============

mp.register_script_message("get-omf-event", function(vod_id, title, year)
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

    fetch_omofun_detail(vod_id, function(entry)
        if not entry or entry.count == 0 then
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
            items[#items + 1] = {
                title = episode_label(e.title, i),
                value = { "script-message-to", mp.get_script_name(), "add-omf-event",
                    tostring(vod_id), tostring(i), title, tostring(year), e.title },
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

mp.register_script_message("add-omf-event", function(vod_id, ep, title, year, ep_title)
    load_omofun_danmaku(vod_id, ep, title, year, ep_title)
    mark_details_episode_added({ "script-message-to", mp.get_script_name(),
        "add-omf-event", vod_id, ep, title, year, ep_title })
end)
