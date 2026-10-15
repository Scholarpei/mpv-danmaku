-- 爱壹帆（yfsp.tv）关键词搜索流程（搜索后缀 |ayf）
-- 接口（App API 逆向签名链路，签名与响应形态见 modules/aiyifan_parse.lua、
--   签名客户端在 sites/aiyifan.lua——本文件 require 之共用内存密钥缓存）：
--   POST api/List/GetTitleGetData 搜索（分集内嵌仅为 6 条预览且无 uniqueID 不可用）→
--   选条目后 POST api/Video/VideoChooseGather 拉全量选集渲染菜单 →
--   选集后拼 https://www.yfsp.tv/play/{mediaKey}?id={episodeKey}&videoId={uniqueID}
--   &videoType={n} 规范 URL 交给 add_danmaku_source 现有管线（yfsp.tv 域名跳过
--   extcomment 直连 sites/aiyifan.lua）
-- 历史续载：DANMAKU.extra 记 kind="ayf"（含 media_key，续载重抓选集按列表序定位目标集
--   的 uniqueID——uniqueID 每集独立且与集数无规律，必须重查），main.lua 的
--   dandanplay_flow 按 kind 分发

local msg = require("mp.msg")
local utils = require("mp.utils")
local aparse = require("modules/aiyifan_parse")
require("sites/aiyifan")  -- App 签名客户端（ayf_signed_post；搜索/选集共用密钥缓存）

local SEARCH_PATH = "/api/List/GetTitleGetData"
local EPISODES_PATH = "/api/Video/VideoChooseGather"
local PLAY_BASE = "https://www.yfsp.tv/play/"

-- ============ 选集列表（菜单与续载共用） ============

-- mediaKey → [{episode_key, video_id, title, video_type}]（列表序=集数序）
local function fetch_aiyifan_episodes(media_key, callback)
    return ayf_signed_post(EPISODES_PATH, { mediaKey = tostring(media_key) }, function(d)
        if d == nil then
            msg.warn("爱壹帆选集请求失败 mediaKey=" .. tostring(media_key))
            callback(nil)
            return
        end
        local parsed = aparse.parse_episodes(d)
        if not parsed.ok or #parsed.episodes == 0 then
            msg.warn("爱壹帆选集为空 mediaKey=" .. tostring(media_key))
            callback(nil)
            return
        end
        callback(parsed.episodes)
    end, 15)
end

-- ============ 选集后加载（菜单选集与历史续载共用） ============

-- 集标题显示规整用全局 episode_label（modules/utils.lua，纯数字规整「第N集」、
-- 非数字（剧场版"正片"等）原样、缺失回退序号）

local function load_aiyifan_danmaku(media_key, episode_key, video_id, video_type,
                                     episodenum, title, ep_title)
    ENABLED = true
    DANMAKU.anime = title
    DANMAKU.episode = episode_label(ep_title, episodenum)
    DANMAKU.source = "ayf"
    DANMAKU.extra = {
        kind = "ayf",
        media_key = tostring(media_key),
        title = title,
        episodenum = tonumber(episodenum) or 1,
    }
    write_history()
    -- 同源单选收紧：驱逐爱壹帆旧集源（标记层 exclusive 同步，见 add-ayf-event）
    local src_url = ("%s%s?id=%s&videoId=%s&videoType=%s"):format(
        PLAY_BASE, media_key, episode_key, video_id, video_type or "1")
    remove_same_provider_sources("爱壹帆", src_url)
    add_danmaku_source(src_url, true, "爱壹帆",
        { anime = DANMAKU.anime, episode = DANMAKU.episode, kind = "ayf" })
end

-- 历史续载入口：按 kind="ayf" 记录重抓选集、按列表序定位目标集，由 main.lua 调入；
-- 超出集数按失败上报不静默
function resume_aiyifan_episode(extra, episodenum)
    fetch_aiyifan_episodes(extra.media_key, function(eps)
        if not eps then
            source_status.mark_failed("extra:ayf", "无法获取集数列表", "爱壹帆弹幕续载失败")
            return
        end
        local ep = eps[tonumber(episodenum)]
        if not ep then
            source_status.mark_failed("extra:ayf",
                ("第 %d 集｜共 %d 集"):format(episodenum, #eps), "爱壹帆弹幕续载失败")
            return
        end
        load_aiyifan_danmaku(extra.media_key, ep.episode_key, ep.video_id, ep.video_type,
            episodenum, extra.title, ep.title)
    end)
end

-- 下一集预取：目标集数 → 对应 uniqueID → 拉弹幕写 ayf: 磁盘缓存（sites/aiyifan.lua；
-- 仅取选集与弹幕，无 OSD/history/sources 副作用，与 resume 路径同源）
function prefetch_aiyifan_episode(extra, episodenum, callback)
    callback = callback or function() end
    fetch_aiyifan_episodes(extra.media_key, function(eps)
        local ep = eps and eps[tonumber(episodenum)]
        if not ep or not ep.video_id then
            callback(false)
            return
        end
        prefetch_aiyifan_danmaku(extra.media_key, ep.video_id, ep.video_type, callback)
    end)
end

-- ============ 搜索 ============

-- 搜索解析结果 → menu_anime 条目（|ayf 单源流与聚合搜索共用）；
-- hint 标注媒体类型（动漫/电影/电视剧/综艺·内容类型，不强制过滤由用户自挑）
function build_aiyifan_search_items(parsed_items)
    local items = {}
    for _, it in ipairs(parsed_items) do
        local type_txt = it.media_type ~= "" and it.media_type or "影视"
        if it.content_type ~= "" then
            type_txt = type_txt .. "·" .. it.content_type
        end
        items[#items + 1] = {
            title = it.title,
            hint = "爱壹帆 | " .. type_txt,
            value = { "script-message-to", mp.get_script_name(), "get-ayf-event",
                it.media_key, it.title },
        }
    end
    return items
end

-- 仅取数：搜索异步请求；callback(items, err)，返回取消函数
function fetch_aiyifan_search(query, callback, timeout)
    return ayf_signed_post(SEARCH_PATH, { SearchCriteria = query }, function(d)
        if d == nil then
            callback(nil, "请求失败")
            return
        end
        local parsed = aparse.parse_search(d)
        if not parsed.ok then
            callback(nil, "接口错误")
            return
        end
        callback(build_aiyifan_search_items(parsed.items), nil)
    end, timeout or 15)
end

-- |ayf 搜索入口（menu.lua 按 |ayf 后缀调入）
function query_aiyifan_search(name)
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
        fetch_aiyifan_search(query, function(items, err)
            if err then
                msg.error("爱壹帆 搜索失败：" .. tostring(err))
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

-- ============ 菜单消息 ============

mp.register_script_message("get-ayf-event", function(media_key, title)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_anime")
    end

    local menu_type = "menu_details"
    local menu_title = title
    local footnote = "使用 / 打开筛选"
    if uosc_available then
        update_menu_uosc(menu_type, menu_title, "加载数据中...", footnote)
    else
        show_message("查询弹幕中...", 3)
    end

    fetch_aiyifan_episodes(media_key, function(eps)
        if not eps then
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
        for i, e in ipairs(eps) do
            items[#items + 1] = {
                title = episode_label(e.title, i),
                value = { "script-message-to", mp.get_script_name(), "add-ayf-event",
                    media_key, e.episode_key, e.video_id, e.video_type,
                    tostring(i), title, e.title },
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

mp.register_script_message("add-ayf-event", function(media_key, episode_key, video_id,
                                                     video_type, episodenum, title, ep_title)
    load_aiyifan_danmaku(media_key, episode_key, video_id, video_type,
        episodenum, title, ep_title)
    mark_details_episode_added({ "script-message-to", mp.get_script_name(),
        "add-ayf-event", media_key, episode_key, video_id, video_type,
        episodenum, title, ep_title })
end)
