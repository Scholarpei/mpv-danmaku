-- AcFun（A站）关键词搜索流程（搜索后缀 |acf）
-- 接口（全部 GET www.acfun.cn，大陆直连，见 modules/acfun_parse.lua）：
--   /search?keyword=<kw> 服务端 BigPipe 渲染 → pagelet_video（单视频 /v/ac{ac号}）+
--   pagelet_album（多P合集 /a/aa{aa号}；番剧区 pagelet_bangumi 实测恒空不解析）→
--   选条目后按类型抓 video 页（多P videoList）/ album 页（contentList 分P）渲染选集菜单 →
--   选集后拼 https://www.acfun.cn/v/ac{ac号}?part={n} 规范 URL 交给 add_danmaku_source
--   现有管线（AcFun 域名跳过 extcomment 直连 sites/acfun.lua）
-- 历史续载：DANMAKU.extra 记 kind="acf"（含 aa_id 时走合集分P推算），main.lua 的
--   dandanplay_flow 按 kind 分发

local msg = require("mp.msg")
local utils = require("mp.utils")
local aparse = require("modules/acfun_parse")

local BASE = "https://www.acfun.cn"
local SEARCH_URL = BASE .. "/search?keyword="
local VIDEO_PAGE = BASE .. "/v/ac"
local ALBUM_PAGE = BASE .. "/a/aa"
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

local function build_get_args(url)
    local args = {
        'curl', '-L', '-s', '--ssl-no-revoke', '--compressed',
        '--user-agent', UA,
        '-H', 'Referer: ' .. BASE .. '/',
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

-- 视频条目 → 分P列表 [{ac_id 同源, part=n, title}]（单P 也走同形状，菜单只有一行）
local function fetch_video_parts(ac_id, callback)
    fetch_page(VIDEO_PAGE .. ac_id, 15, function(html)
        if not html then
            callback(nil)
            return
        end
        local parsed = aparse.parse_video_page(html)
        if not parsed.ok then
            callback(nil)
            return
        end
        local parts = {}
        for i, v in ipairs(parsed.videos) do
            parts[#parts + 1] = { ac_id = tostring(ac_id), part = i, title = v.title }
        end
        callback(parts)
    end)
end

-- 合集条目 → 分P列表 [{ac_id=各P独立ac号, part=1, title}]
local function fetch_album_parts(aa_id, callback)
    fetch_page(ALBUM_PAGE .. aa_id, 15, function(html)
        if not html then
            callback(nil)
            return
        end
        local parsed = aparse.parse_album_page(html)
        if not parsed.ok then
            callback(nil)
            return
        end
        local parts = {}
        for i, p in ipairs(parsed.parts) do
            parts[#parts + 1] = { ac_id = p.ac_id, part = 1, title = p.title }
        end
        callback(parts)
    end)
end

local function fetch_parts_by_type(item_type, id, callback)
    if item_type == "album" then
        fetch_album_parts(id, callback)
    else
        fetch_video_parts(id, callback)
    end
end

-- ============ 选集后加载（菜单选集与历史续载共用） ============

local function load_acfun_danmaku(ac_id, part, episodenum, title, part_title, aa_id)
    ENABLED = true
    DANMAKU.anime = title
    -- 源端真实分P标题优先（全局 episode_label 规整），缺失回退序号
    DANMAKU.episode = episode_label(part_title, episodenum)
    DANMAKU.source = "acf"
    DANMAKU.extra = {
        kind = "acf",
        ac_id = tostring(ac_id),
        part = tonumber(part) or 1,
        aa_id = aa_id and aa_id ~= "" and tostring(aa_id) or nil,
        title = title,
        episodenum = tonumber(episodenum) or 1,
    }
    write_history()
    -- 同源单选收紧：驱逐 AcFun 旧集源（标记层 exclusive 同步，见 add-acf-event）
    local src_url = ("https://www.acfun.cn/v/ac%s?part=%d"):format(ac_id, part)
    remove_same_provider_sources("AcFun", src_url)
    add_danmaku_source(src_url, true, "AcFun",
        { anime = DANMAKU.anime, episode = DANMAKU.episode, kind = "acf" })
end

-- 历史续载入口：按 kind="acf" 记录推算目标集数后由 main.lua 调入
-- aa_id 在场 → 重抓合集页按 contentList 序取第 episodenum 个分P；
-- 否则为多P/单P视频 → part 即集数序（超出分P数按失败上报）
function resume_acfun_episode(extra, episodenum)
    if extra.aa_id then
        fetch_album_parts(extra.aa_id, function(parts)
            if not parts then
                source_status.mark_failed("extra:acf", "无法获取合集列表", "AcFun弹幕续载失败")
                return
            end
            local p = parts[episodenum]
            if not p then
                source_status.mark_failed("extra:acf",
                    ("第 %d 集｜合集共 %d 个分P"):format(episodenum, #parts), "AcFun弹幕续载失败")
                return
            end
            load_acfun_danmaku(p.ac_id, p.part, episodenum, extra.title, p.title, extra.aa_id)
        end)
    else
        fetch_video_parts(extra.ac_id, function(parts)
            if not parts then
                source_status.mark_failed("extra:acf", "无法获取视频分P列表", "AcFun弹幕续载失败")
                return
            end
            local p = parts[episodenum]
            if not p then
                source_status.mark_failed("extra:acf",
                    ("第 %d 集｜视频共 %d 个分P"):format(episodenum, #parts), "AcFun弹幕续载失败")
                return
            end
            load_acfun_danmaku(p.ac_id, p.part, episodenum, extra.title, p.title, nil)
        end)
    end
end

-- 下一集预取：目标集数 → 对应分P → 拉弹幕写 acf: 磁盘缓存（sites/acfun.lua；
-- 仅取分P列表与弹幕，无 OSD/history/sources 副作用，与 resume 路径同源）
function prefetch_acfun_episode(extra, episodenum, callback)
    callback = callback or function() end
    fetch_parts_by_type(extra.aa_id and "album" or "video",
        extra.aa_id or extra.ac_id, function(parts)
        local p = parts and parts[episodenum]
        if not p or not p.ac_id then
            callback(false)
            return
        end
        prefetch_acfun_danmaku(p.ac_id, p.part or 1, callback)
    end)
end

-- ============ 搜索 ============

-- 搜索解析结果 → menu_anime 条目（|acf 单源流与聚合搜索共用）
-- 合集（季包）在前视频在后：parse 按页面 pagelet 顺序产出即此序
function build_acfun_search_items(parsed_items)
    local items = {}
    for _, it in ipairs(parsed_items) do
        if it.type == "album" then
            items[#items + 1] = {
                title = it.title ~= "" and it.title or ("合集 aa" .. it.aa_id),
                hint = "A站合集 | " .. it.user,
                value = { "script-message-to", mp.get_script_name(), "get-acf-event",
                    "album", it.aa_id, it.title },
            }
        else
            items[#items + 1] = {
                title = it.title ~= "" and it.title or ("视频 ac" .. it.ac_id),
                hint = "A站 | " .. (it.danmu ~= "" and it.danmu or "无弹幕数据"),
                value = { "script-message-to", mp.get_script_name(), "get-acf-event",
                    "video", it.ac_id, it.title },
            }
        end
    end
    return items
end

-- 仅取数：搜索异步请求；callback(items, err)，返回取消函数
function fetch_acfun_search(query, callback, timeout)
    return fetch_page(SEARCH_URL .. url_encode(query), timeout or 15, function(html)
        if not html then
            callback(nil, "请求失败")
            return
        end
        local parsed = aparse.parse_search(html)
        if not parsed.ok then
            callback(nil, "接口错误")
            return
        end
        callback(build_acfun_search_items(parsed.items), nil)
    end)
end

-- |acf 搜索入口（menu.lua 按 |acf 后缀调入）
function query_acfun_search(name)
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
        fetch_acfun_search(query, function(items, err)
            if err then
                msg.error("AcFun 搜索失败：" .. tostring(err))
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

mp.register_script_message("get-acf-event", function(item_type, id, title)
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

    fetch_parts_by_type(item_type, id, function(parts)
        if not parts then
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
        for i, p in ipairs(parts) do
            items[#items + 1] = {
                title = p.title ~= "" and p.title or ("第" .. i .. "集"),
                value = { "script-message-to", mp.get_script_name(), "add-acf-event",
                    p.ac_id, tostring(p.part), tostring(i), title, p.title, item_type == "album" and id or "" },
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

mp.register_script_message("add-acf-event", function(ac_id, part, episodenum, title, part_title, aa_id)
    load_acfun_danmaku(ac_id, part, episodenum, title, part_title, aa_id)
    mark_details_episode_added({ "script-message-to", mp.get_script_name(),
        "add-acf-event", ac_id, part, episodenum, title, part_title, aa_id })
end)
