-- ezdmw（E站弹幕网）关键词搜索流程（搜索后缀 |ezd）
-- 接口（全部 GET www.ezdmw.org，大陆直连，见 modules/ezdmw_parse.lua）：
--   /Index/search.html?searchText=<kw> → some_drama 区 bangumi 条目 →
--   选条目后抓 /Index/bangumi/{bangumiId}.html 集数列表（主线线路）渲染选集菜单 →
--   选集后拼 https://www.ezdmw.org/Index/video/{videoId}.html 规范 URL 交给
--   add_danmaku_source 现有管线（ezdmw 域名跳过 extcomment 直连 sites/ezdmw.lua）
-- 多季番：详情页 span 为「{季}-{集}」（2-13=第二季第13集），菜单/续载/预取的集数定位
--   一律用 eparse.episode_key(season, ep) 复合键（S1 纯集数兼容旧历史，S2+ 季*10000+集）
-- 历史续载：DANMAKU.extra 记 kind="ezd"（含 bangumi_id，续载重抓集数表按集数复合键定位
--   目标集的 videoId——videoId 每集独立且与集数无规律，必须重查），main.lua 的
--   dandanplay_flow 按 kind 分发

local msg = require("mp.msg")
local utils = require("mp.utils")
local eparse = require("modules/ezdmw_parse")

local BASE = "https://www.ezdmw.org"
local SEARCH_URL = BASE .. "/Index/search.html?searchText="
local BANGUMI_PAGE = BASE .. "/Index/bangumi/"
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

local function build_get_args(url)
    local args = {
        'curl', '-L', '-s', '--ssl-no-revoke', '--compressed',
        '--user-agent', UA,
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

-- ============ 选集列表（菜单与续载共用） ============

-- bangumiId → 集数列表 [{video_id, ep, season}]（主线线路，按 (季,集) 升序=正片顺序；
-- 多季番 season>1，集数定位一律用 eparse.episode_key(season, ep) 复合键）
local function fetch_ezdmw_episodes(bangumi_id, callback)
    fetch_page(BANGUMI_PAGE .. tostring(bangumi_id) .. ".html", 15, function(html)
        if not html then
            callback(nil)
            return
        end
        local parsed = eparse.parse_detail(html)
        if not parsed.ok then
            callback(nil)
            return
        end
        callback(parsed.episodes)
    end)
end

-- ============ 选集后加载（菜单选集与历史续载共用） ============

local function load_ezdmw_danmaku(bangumi_id, video_id, episodenum, title)
    ENABLED = true
    DANMAKU.anime = title
    DANMAKU.episode = eparse.episode_label(episodenum)
    DANMAKU.source = "ezd"
    DANMAKU.extra = {
        kind = "ezd",
        bangumi_id = tostring(bangumi_id),
        title = title,
        episodenum = tonumber(episodenum) or 1,
    }
    write_history()
    -- 同源单选收紧：驱逐 ezdmw 旧集源（标记层 exclusive 同步，见 add-ezd-event）
    local src_url = ("https://www.ezdmw.org/Index/video/%s.html"):format(video_id)
    remove_same_provider_sources("ezdmw", src_url)
    add_danmaku_source(src_url, true, "ezdmw",
        { anime = DANMAKU.anime, episode = DANMAKU.episode, kind = "ezd" })
end

-- 历史续载入口：按 kind="ezd" 记录重抓集数表、按集数复合键定位目标集的 videoId，
-- 由 main.lua 调入；超出集数按失败上报不静默
function resume_ezdmw_episode(extra, episodenum)
    fetch_ezdmw_episodes(extra.bangumi_id, function(eps)
        if not eps then
            source_status.mark_failed("extra:ezd", "无法获取集数列表", "ezdmw弹幕续载失败")
            return
        end
        local target
        for _, e in ipairs(eps) do
            if eparse.episode_key(e.season, e.ep) == tonumber(episodenum) then
                target = e
                break
            end
        end
        if not target then
            source_status.mark_failed("extra:ezd",
                eparse.episode_label(episodenum) .. "｜共 " .. #eps .. " 集",
                "ezdmw弹幕续载失败")
            return
        end
        load_ezdmw_danmaku(extra.bangumi_id, target.video_id, episodenum, extra.title)
    end)
end

-- 下一集预取：目标集数复合键 → 对应 videoId → 拉弹幕写 ezd: 磁盘缓存（sites/ezdmw.lua；
-- 仅取集数表与弹幕，无 OSD/history/sources 副作用，与 resume 路径同源）
function prefetch_ezdmw_episode(extra, episodenum, callback)
    callback = callback or function() end
    fetch_ezdmw_episodes(extra.bangumi_id, function(eps)
        local target
        for _, e in ipairs(eps) do
            if eparse.episode_key(e.season, e.ep) == tonumber(episodenum) then
                target = e
                break
            end
        end
        if not target or not target.video_id then
            callback(false)
            return
        end
        prefetch_ezdmw_danmaku(target.video_id, callback)
    end)
end

-- ============ 搜索 ============

-- 搜索解析结果 → menu_anime 条目（|ezd 单源流与聚合搜索共用）
function build_ezdmw_search_items(parsed_items)
    local items = {}
    for _, it in ipairs(parsed_items) do
        items[#items + 1] = {
            title = it.title ~= "" and it.title or ("ezdmw " .. it.bangumi_id),
            hint = "E站 | 番剧",
            value = { "script-message-to", mp.get_script_name(), "get-ezd-event",
                it.bangumi_id, it.title },
        }
    end
    return items
end

-- 仅取数：搜索异步请求；callback(items, err)，返回取消函数
function fetch_ezdmw_search(query, callback, timeout)
    return fetch_page(SEARCH_URL .. url_encode(query), timeout or 15, function(html)
        if not html then
            callback(nil, "请求失败")
            return
        end
        local parsed = eparse.parse_search(html)
        if not parsed.ok then
            callback(nil, "接口错误")
            return
        end
        callback(build_ezdmw_search_items(parsed.items), nil)
    end)
end

-- |ezd 搜索入口（menu.lua 按 |ezd 后缀调入）
function query_ezdmw_search(name)
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
        fetch_ezdmw_search(query, function(items, err)
            if err then
                msg.error("ezdmw 搜索失败：" .. tostring(err))
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

mp.register_script_message("get-ezd-event", function(bangumi_id, title)
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

    fetch_ezdmw_episodes(bangumi_id, function(eps)
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
        for _, e in ipairs(eps) do
            -- 多季番标题与集数键均按复合键派生（第2季13集 / 20013）
            local key = eparse.episode_key(e.season, e.ep)
            items[#items + 1] = {
                title = eparse.episode_label(key),
                value = { "script-message-to", mp.get_script_name(), "add-ezd-event",
                    tostring(bangumi_id), e.video_id, tostring(key), title },
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

mp.register_script_message("add-ezd-event", function(bangumi_id, video_id, episodenum, title)
    load_ezdmw_danmaku(bangumi_id, video_id, episodenum, title)
    mark_details_episode_added({ "script-message-to", mp.get_script_name(),
        "add-ezd-event", bangumi_id, video_id, episodenum, title })
end)
