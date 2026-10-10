-- 巴哈姆特动画疯关键词搜索流程（搜索后缀 |baha）
-- 接口：
--   api.gamer.com.tw/mobile_app/anime/v1/search.php 搜索（iOS App UA，关键词先简→繁）→
--   api.gamer.com.tw/anime/v1/video.php 分集列表（videoSn → 每集 sn）→
--   选集后拼 ani.gamer.com.tw/animeVideo.php?sn=<sn> 规范 URL 交给 add_danmaku_source
--   现有管线（extcomment → 域名直连 sites/bahamut.lua → dmku 兜底）
-- 注意：搜索与弹幕接口大陆直连可达，但分集接口（video.php 的 anime 数据段）实测对
--   大陆出口 IP 受限——受限时菜单提示需配置代理（options.proxy 或台湾节点）
-- 历史续载：DANMAKU.extra 记 kind="bahamut"，main.lua 的 dandanplay_flow 按 kind 分发

local msg = require("mp.msg")
local utils = require("mp.utils")
local s2t = require("dicts/s2t_chars")
local bparse = require("modules/bahamut_parse")

local APP_UA = 'Anime/2.29.2 (7N5749MM3F.tw.com.gamer.anime; build:972; iOS 26.0.0) Alamofire/5.6.4'

local SEARCH_URL = "https://api.gamer.com.tw/mobile_app/anime/v1/search.php"
local VIDEO_URL = "https://api.gamer.com.tw/anime/v1/video.php"

-- 简体 → 繁体（巴哈站内标题均为繁体，简体关键词命中率低；逐字查表与 parse.lua 同法）
local function traditionalize(s)
    return (s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
        return s2t[c] or c
    end))
end

-- 构造巴哈 GET 请求参数（iOS App UA）
local function build_baha_args(url)
    local args = {
        'curl',
        '-L',
        '-s',
        '--compressed',
        '--user-agent',
        APP_UA,
        '-H', 'Content-Type: application/json',
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

-- 拉取分集列表：videoSn → 每集 sn；callback(episodes)，失败/受限传 nil + restricted 标记
-- video.php 的 anime 数据段间歇性返回空（多 CDN 节点对大陆直连表现不一），
-- 失败时重试最多 3 次（间隔 0.8s），命中正常节点即成功
local function fetch_baha_episodes(video_sn, callback)
    local attempt = 0
    local function attempt_once()
        attempt = attempt + 1
        call_cmd_async_with_timeout(build_baha_args(VIDEO_URL .. "?videoSn=" .. url_encode(video_sn)),
            15, function(err, out)
                if err then
                    msg.warn(("巴哈分集第 %d 次请求失败: %s"):format(attempt, tostring(err)))
                else
                    local parsed = bparse.parse_video_info(utils.parse_json(out))
                    if parsed.ok then
                        callback(parsed.episodes, false)
                        return
                    end
                    if not parsed.restricted then
                        -- 结构异常（非典型受限形态）也纳入重试
                        msg.warn(("巴哈分集第 %d 次解析失败"):format(attempt))
                    end
                end
                if attempt < 3 then
                    mp.add_timeout(1.0, attempt_once)
                else
                    -- 三次皆空按受限处理（该接口对大陆直连时段性关闭，窗口期可成功）
                    callback(nil, true)
                end
            end)
    end
    attempt_once()
end

-- 选集后加载（菜单选集与历史续载共用）
local function load_bahamut_danmaku(video_sn, ep_sn, episodenum, title, year)
    ENABLED = true
    DANMAKU.anime = title .. " (" .. year .. ")"
    DANMAKU.episode = "第" .. episodenum .. "话"
    DANMAKU.source = "bahamut"
    DANMAKU.extra = {
        kind = "bahamut",
        video_sn = tostring(video_sn),
        title = title,
        year = tonumber(year) or year,
        episodenum = tonumber(episodenum),
    }
    write_history()
    add_danmaku_source(("https://ani.gamer.com.tw/animeVideo.php?sn=%s"):format(ep_sn), true, "巴哈姆特")
end

-- 历史续载入口：按 kind="bahamut" 记录推算目标集数后由 main.lua 调入
function resume_bahamut_episode(extra, episodenum)
    fetch_baha_episodes(extra.video_sn, function(episodes, restricted)
        if not episodes then
            if restricted then
                show_message("巴哈分集接口当前受限（时段性），稍后重试或配置代理", 4)
            else
                show_message("巴哈弹幕续载失败：无法获取剧集列表", 3)
            end
            msg.warn("巴哈续载：剧集列表为空 video_sn=" .. tostring(extra.video_sn))
            return
        end
        local ep = episodes[episodenum]
        if not ep then
            show_message(("巴哈弹幕续载失败：第 %d 话不存在（共 %d 话）")
                :format(episodenum, #episodes), 3)
            return
        end
        load_bahamut_danmaku(extra.video_sn, ep.video_sn, episodenum, extra.title, extra.year)
    end)
end

-- 搜索解析结果 → menu_anime 条目（|baha 单源流与聚合搜索共用）
function build_bahamut_search_items(parsed_items)
    local items = {}
    for _, it in ipairs(parsed_items) do
        items[#items + 1] = {
            title = it.title,
            hint = "动画疯 | " .. it.year,
            value = { "script-message-to", mp.get_script_name(), "get-baha-event",
                it.video_sn, it.title, tostring(it.year) },
        }
    end
    return items
end

-- 仅取数：搜索异步请求（自动重试一次）；callback(items, err)，返回取消函数
function fetch_bahamut_search(query, callback, timeout)
    local kw = traditionalize(query)
    local url = SEARCH_URL .. "?kw=" .. url_encode(kw)
    local attempts = 0
    local cancel = nil
    local function run()
        cancel = call_cmd_async_with_timeout(build_baha_args(url), timeout, function(err, out)
            if err then
                attempts = attempts + 1
                if attempts <= 1 then
                    msg.warn("巴哈搜索失败重试: " .. tostring(err))
                    run()
                    return
                end
                callback(nil, "请求失败")
                return
            end
            local parsed = bparse.parse_search(utils.parse_json(out))
            if not parsed.ok then
                callback(nil, "接口错误")
                return
            end
            callback(build_bahamut_search_items(parsed.items), nil)
        end)
    end
    run()
    return function()
        if cancel then pcall(cancel) end
    end
end

-- |baha 搜索入口（menu.lua 按 |baha 后缀调入）
function query_bahamut_search(name)
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
        fetch_bahamut_search(query, function(items, err)
            if err then
                msg.error("巴哈搜索失败：" .. tostring(err))
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

    -- 非中文关键词先经 TMDB 换译名；失败不阻断（巴哈搜索内部再做简→繁）
    if not is_chinese(name) and type(query_tmdb) == "function"
        and options.tmdb_api_key ~= "" and #Base64.decode(options.tmdb_api_key) >= 32 then
        local title = query_tmdb(name, "tv", menu)
        if title then
            name = title
        end
    end
    search(name)
end

mp.register_script_message("get-baha-event", function(video_sn, title, year)
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

    fetch_baha_episodes(video_sn, function(episodes, restricted)
        local message = nil
        if not episodes then
            message = restricted and "分集接口当前受限，稍后重试或配置代理" or "无结果"
        end
        if message then
            if uosc_available then
                update_menu_uosc(menu_type, menu_title, message, footnote)
            else
                show_message(message, 4)
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
            -- 显示巴哈原始话数编号（跨季连续，如第二季从 29 起）；value 仍传列表序保证续载对齐
            local display_no = tonumber(ep.episode) or i
            items[#items + 1] = {
                title = "第" .. display_no .. "话",
                value = { "script-message-to", mp.get_script_name(), "add-baha-event",
                    video_sn, ep.video_sn, tostring(i), title, year },
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

mp.register_script_message("add-baha-event", function(video_sn, ep_sn, episodenum, title, year)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_details")
    end
    load_bahamut_danmaku(video_sn, ep_sn, episodenum, title, year)
end)
