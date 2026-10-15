-- girigirilove（girigiri愛動漫）关键词搜索流程（搜索后缀 |ggl）
-- 接口（全部 ani.girigirilove.com，大陆直连，见 modules/ggl_parse.lua）：
--   /index.php/ajax/suggest?mid=1&wd=<kw>（站内搜索框自动补全端点，公开 JSON；
--   HTML 搜索页配反爬 bot 恒空不可用）→ 条目 {id=GV号, name} →
--   选条目后抓 /GV{GV号}/ 集数列表（首条非空线路——弹幕接口按资源名模糊匹配，
--   繁/简线路实测同池，线路选择不影响弹幕内容）渲染选集菜单 →
--   选集后拼 https://ani.girigirilove.com/playGV{GV}-{线路src}-{集ep}/ 规范 URL 交给
--   add_danmaku_source 现有管线（girigirilove 域名跳过 extcomment 直连 sites/ggl.lua）
-- 历史续载：DANMAKU.extra 记 kind="ggl"（含 gv_id/src/title，续载重抓线路表按集数号
--   定位目标集，优先原线路、原线路缺该集时落其他线路），main.lua 的 dandanplay_flow
--   按 kind 分发

local msg = require("mp.msg")
local utils = require("mp.utils")
local gparse = require("modules/ggl_parse")

local BASE = "https://ani.girigirilove.com"
local SUGGEST_URL = BASE .. "/index.php/ajax/suggest?mid=1&wd="
local DETAIL_PAGE = BASE .. "/GV"
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

-- GV号 → 线路表 [{label, episodes}]（网络/解析失败 callback(nil)）
local function fetch_ggl_lines(gv_id, callback)
    fetch_page(DETAIL_PAGE .. tostring(gv_id) .. "/", 15, function(html)
        if not html then
            callback(nil)
            return
        end
        local parsed = gparse.parse_detail(html)
        if not parsed.ok then
            callback(nil)
            return
        end
        callback(parsed.lines)
    end)
end

-- 线路表中定位目标集：优先指定线路（续载原线路），其缺该集时落其他线路
-- （弹幕按资源名模糊匹配同池，线路差异不影响弹幕内容，保命优先）
-- → {gv, src, ep} 或 nil
local function find_episode(lines, prefer_src, ep)
    local fallback
    for _, line in ipairs(lines) do
        for _, e in ipairs(line.episodes) do
            if e.ep == tonumber(ep) then
                if tonumber(prefer_src) == e.src then
                    return e
                end
                fallback = fallback or e
            end
        end
    end
    return fallback
end

-- ============ 选集后加载（菜单选集与历史续载共用） ============

local function load_ggl_danmaku(gv_id, src, ep, title, ep_display)
    ENABLED = true
    DANMAKU.anime = title
    -- 源端真实分集标签（如「先行01」/「1080P」，与选集菜单同款 episode_title 格式），
    -- 缺失才回退站点集数号
    DANMAKU.episode = (ep_display ~= nil and ep_display ~= "")
        and ep_display or ("第" .. ep .. "集")
    DANMAKU.source = "ggl"
    DANMAKU.extra = {
        kind = "ggl",
        gv_id = tostring(gv_id),
        src = tonumber(src) or 1,
        title = title,
        episodenum = tonumber(ep) or 1,
    }
    write_history()
    -- 同源单选收紧：驱逐 girigirilove 旧集源（标记层 exclusive 同步，见 add-ggl-event）
    local src_url = ("https://ani.girigirilove.com/playGV%s-%s-%s/"):format(gv_id, src, ep)
    remove_same_provider_sources("girigirilove", src_url)
    add_danmaku_source(src_url, true, "girigirilove",
        { anime = DANMAKU.anime, episode = DANMAKU.episode, kind = "ggl" })
end

-- 历史续载入口：按 kind="ggl" 记录重抓线路表、按集数号定位目标集，
-- 由 main.lua 调入；超出集数按失败上报不静默
function resume_ggl_episode(extra, episodenum)
    fetch_ggl_lines(extra.gv_id, function(lines)
        if not lines then
            source_status.mark_failed("extra:ggl", "无法获取集数列表", "girigirilove弹幕续载失败")
            return
        end
        local target = find_episode(lines, extra.src, episodenum)
        if not target then
            local total = 0
            for _, line in ipairs(lines) do
                if #line.episodes > total then total = #line.episodes end
            end
            source_status.mark_failed("extra:ggl",
                ("第 %d 集｜共 %d 集"):format(episodenum, total), "girigirilove弹幕续载失败")
            return
        end
        load_ggl_danmaku(extra.gv_id, target.src, target.ep, extra.title,
            episode_title(target.label, target.ep))
    end)
end

-- 下一集预取：目标集数 → 对应线路集 → 拉弹幕写 ggl: 磁盘缓存（sites/ggl.lua；
-- 仅取线路表与弹幕，无 OSD/history/sources 副作用，与 resume 路径同源）
function prefetch_ggl_episode(extra, episodenum, callback)
    callback = callback or function() end
    fetch_ggl_lines(extra.gv_id, function(lines)
        local target = lines and find_episode(lines, extra.src, episodenum) or nil
        if not target or not target.gv then
            callback(false)
            return
        end
        prefetch_ggl_danmaku(target.gv, target.src, target.ep, callback)
    end)
end

-- ============ 搜索 ============

-- 搜索解析结果 → menu_anime 条目（|ggl 单源流与聚合搜索共用）
function build_ggl_search_items(parsed_items)
    local items = {}
    for _, it in ipairs(parsed_items) do
        items[#items + 1] = {
            title = it.title ~= "" and it.title or ("girigiri " .. it.gv_id),
            hint = "girigiri | 番剧",
            value = { "script-message-to", mp.get_script_name(), "get-ggl-event",
                it.gv_id, it.title },
        }
    end
    return items
end

-- 仅取数：搜索异步请求；callback(items, err)，返回取消函数
function fetch_ggl_search(query, callback, timeout)
    return fetch_page(SUGGEST_URL .. url_encode(query), timeout or 15, function(raw)
        if not raw then
            callback(nil, "请求失败")
            return
        end
        local parsed = gparse.parse_search(raw)
        if not parsed.ok then
            callback(nil, "接口错误")
            return
        end
        callback(build_ggl_search_items(parsed.items), nil)
    end)
end

-- |ggl 搜索入口（menu.lua 按 |ggl 后缀调入）
function query_ggl_search(name)
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
        fetch_ggl_search(query, function(items, err)
            if err then
                msg.error("girigirilove 搜索失败：" .. tostring(err))
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

-- 集数标签 → 菜单条目标题：纯数字（01/02…）格式化为「第NN集」，
-- 其余（先行01/1080P）原样展示
local function episode_title(label, ep)
    if type(label) == "string" and label ~= "" then
        if label:match("^%d+$") then return "第" .. label .. "集" end
        return label
    end
    return "第" .. tostring(ep) .. "集"
end

mp.register_script_message("get-ggl-event", function(gv_id, title)
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

    fetch_ggl_lines(gv_id, function(lines)
        if not lines then
            local message = "无结果"
            if uosc_available then
                update_menu_uosc(menu_type, menu_title, message, footnote)
            else
                show_message(message, 3)
            end
            return
        end

        -- 弹幕按资源名模糊匹配同池：取首条非空线路即可（ezdmw 主线线路同口径）
        local line = lines[1]
        for _, l in ipairs(lines) do
            if #l.episodes > 0 then
                line = l
                break
            end
        end
        if not line or #line.episodes == 0 then
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
        for _, e in ipairs(line.episodes) do
            local ep_display = episode_title(e.label, e.ep)
            items[#items + 1] = {
                title = ep_display,
                value = { "script-message-to", mp.get_script_name(), "add-ggl-event",
                    gv_id, tostring(e.src), tostring(e.ep), title, ep_display },
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

mp.register_script_message("add-ggl-event", function(gv_id, src, ep, title, ep_display)
    load_ggl_danmaku(gv_id, src, ep, title, ep_display)
    mark_details_episode_added({ "script-message-to", mp.get_script_name(),
        "add-ggl-event", gv_id, src, ep, title, ep_display })
end)
