-- 腾讯视频关键词搜索流程（搜索后缀 |tx）
-- 接口为 pbaccess.video.qq.com 公开接口（无鉴权），复刻自 danmaku-anywhere 的 tencent provider：
--   MbSearch 搜索（关键词 → cid）→ GetPageData 剧集列表（cid → 每集 vid，每页100集顺序翻页）→
--   选集后拼规范播放页 URL 交给 add_danmaku_source 现有管线（extcomment → 域名直连 v.qq.com
--   即 sites/tencentvideo.lua → dmku 兜底），本文件不直接取弹幕
-- 历史续载：DANMAKU.extra 记 kind="qq"，main.lua 的 dandanplay_flow 按 kind 分发到 resume_tencent_episode

local msg = require("mp.msg")
local utils = require("mp.utils")
local tparse = require("modules/tencent_parse")

local user_agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

local MBSEARCH_URL = "https://pbaccess.video.qq.com/trpc.videosearch.mobile_search.MultiTerminalSearch/MbSearch?vplatform=2"
local PAGEDATA_URL = "https://pbaccess.video.qq.com/trpc.universal_backend_service.page_server_rpc.PageServer/GetPageData?video_appid=3000010&vversion_name=8.2.96&vversion_platform=2"
local PAGE_SIZE = 100
local MAX_PAGES = 20

-- 构造 pbaccess POST 请求参数（浏览器 UA + Origin + Referer；这些接口不需要弹弹play签名头）
-- Origin 必须带：2026-10 起网关校验缺失 Origin 的请求并返回 ret=20607 "unknow error."
-- （浏览器扩展天然带 Origin，故参考实现 danmaku-anywhere 未显式添加）
local function build_pb_args(url, body)
    local args = {
        'curl',
        '-L',
        '-s',
        '--compressed',
        '--user-agent',
        user_agent,
        '-H', 'Content-Type: application/json',
        '-H', 'Origin: https://m.video.qq.com',
        '-H', 'Referer: https://m.video.qq.com/',
        '-X', 'POST',
        '-d', utils.format_json(body),
        url,
    }

    if options.cookie_file and options.cookie_file ~= '' then
        table.insert(args, '-b')
        table.insert(args, mp.command_native({'expand-path', options.cookie_file}))
    end
    if options.proxy ~= '' then
        table.insert(args, '-x')
        table.insert(args, options.proxy)
    end
    return args
end

-- MbSearch 请求体（固定字段照抄 danmaku-anywhere，仅 query 变化）
local function mb_search_body(query)
    return {
        version = "25071701",
        clientType = 1,
        filterValue = "",
        uuid = "0379274D-05A0-4EB6-A89C-878C9A460426",
        query = query,
        retry = 0,
        pagenum = 0,
        isPrefetch = true,
        pagesize = 30,
        queryFrom = 0,
        searchDatakey = "",
        transInfo = "",
        isneedQc = true,
        preQid = "",
        adClientInfo = "",
        extraInfo = {
            multi_terminal_pc = "1",
            themeType = "1",
            sugRelatedIds = "{}",
            appVersion = "",
        },
    }
end

-- GetPageData 第 page_idx 页（0 基）的请求体；pageParams 的值必须全部是字符串
local function episode_body(cid, page_idx)
    local begin_idx = page_idx * PAGE_SIZE + 1
    local end_idx = (page_idx + 1) * PAGE_SIZE
    return {
        has_cache = 1,
        pageParams = {
            cid = tostring(cid),
            lid = "0",
            vid = "",
            req_from = "web_mobile",
            page_type = "detail_operation",
            page_id = "vsite_episode_list",
            id_type = "1",
            page_size = tostring(PAGE_SIZE),
            page_context = ("episode_begin=%d&episode_end=%d&episode_step=%d")
                :format(begin_idx, end_idx, PAGE_SIZE),
        },
    }
end

-- 顺序翻页拉取剧集列表（预告已在 tencent_parse 内过滤，episodes 索引即集数编号）
-- stop_after 非空时集齐该数即停（续载场景只取到目标集）；callback(episodes)，首页即失败时传 nil
local function fetch_tx_episodes(cid, stop_after, callback)
    local episodes = {}
    local page = 0
    local last_vid = nil

    local function fetch_page()
        call_cmd_async(build_pb_args(PAGEDATA_URL, episode_body(cid, page)), function(err, out)
            if err then
                msg.warn(("腾讯剧集列表第 %d 页请求失败: %s"):format(page + 1, tostring(err)))
                callback(page == 0 and nil or episodes)
                return
            end
            local parsed = tparse.parse_episode_page(utils.parse_json(out))
            if not parsed.ok then
                msg.warn("腾讯剧集列表解析失败: " .. (parsed.msg or "ret!=0"))
                callback(page == 0 and nil or episodes)
                return
            end
            local page_last_vid = nil
            for _, ep in ipairs(parsed.episodes) do
                page_last_vid = ep.vid
                episodes[#episodes + 1] = ep
            end
            -- 翻页判停：无下一页标记 / 本页条数不足（has_next_page 缺失时的兜底信号）/
            -- 末条 vid 与上页重复 / 已集齐目标集 / 达到页数上限
            local stop = parsed.has_next_page ~= true
                or parsed.raw_count < PAGE_SIZE
                or (page_last_vid ~= nil and page_last_vid == last_vid)
                or (stop_after ~= nil and #episodes >= stop_after)
                or page + 1 >= MAX_PAGES
            last_vid = page_last_vid
            if stop then
                callback(episodes)
            else
                page = page + 1
                fetch_page()
            end
        end)
    end

    fetch_page()
end

-- 选集后加载（菜单选集与历史续载共用）
local function load_tencent_danmaku(cid, vid, episodenum, title, year, type_name)
    ENABLED = true
    DANMAKU.anime = title .. " (" .. year .. ")"
    DANMAKU.episode = "第" .. episodenum .. "集"
    DANMAKU.source = "qq"
    DANMAKU.extra = {
        kind = "qq",
        cid = tostring(cid),
        title = title,
        year = tonumber(year) or year,
        type_name = type_name,
        episodenum = tonumber(episodenum),
    }
    write_history()
    add_danmaku_source(("https://v.qq.com/x/cover/%s/%s.html"):format(cid, vid), true, "腾讯视频")
end

-- 历史续载入口：按 kind="qq" 记录推算目标集数后由 main.lua 调入
function resume_tencent_episode(extra, episodenum)
    fetch_tx_episodes(extra.cid, episodenum, function(episodes)
        if not episodes or #episodes == 0 then
            show_message("腾讯弹幕续载失败：无法获取剧集列表", 3)
            msg.warn("腾讯续载：剧集列表为空 cid=" .. tostring(extra.cid))
            return
        end
        local ep = episodes[episodenum]
        if not ep then
            show_message(("腾讯弹幕续载失败：第 %d 集不存在（共 %d 集）")
                :format(episodenum, #episodes), 3)
            return
        end
        load_tencent_danmaku(extra.cid, ep.vid, episodenum, extra.title, extra.year, extra.type_name)
    end)
end

-- MbSearch 解析结果 → menu_anime 条目（|tx 单源流与聚合搜索共用）
function build_tencent_search_items(parsed_items)
    local items = {}
    for _, it in ipairs(parsed_items) do
        items[#items + 1] = {
            title = it.title,
            hint = it.type_name .. " | " .. it.year,
            value = { "script-message-to", mp.get_script_name(), "get-tx-event",
                it.cid, it.title, tostring(it.year), it.type_name,
                tostring(it.video_type or "") },
        }
    end
    return items
end

-- 仅取数：MbSearch 异步请求（timeout 为 nil 时不设超时，保持 |tx 旧行为）；
-- callback(items, err)，返回取消函数
function fetch_tencent_search(query, callback, timeout)
    return call_cmd_async_with_timeout(build_pb_args(MBSEARCH_URL, mb_search_body(query)), timeout, function(err, out)
        if err then
            callback(nil, "请求失败")
            return
        end
        local parsed = tparse.parse_mb_search(utils.parse_json(out))
        if not parsed.ok then
            -- 带上接口 msg（如 "unknow error."），菜单错误行可直接看出接口侧原因
            local reason = (parsed.msg and parsed.msg ~= "") and ("：" .. parsed.msg) or ""
            callback(nil, "接口错误" .. reason)
            return
        end
        callback(build_tencent_search_items(parsed.items), nil)
    end)
end

-- |tx 搜索入口（menu.lua 按 |tx 后缀调入）
function query_tencent_search(name)
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
        fetch_tencent_search(query, function(items, err)
            if err then
                msg.error("腾讯搜索失败：" .. tostring(err))
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

    -- 非中文关键词先经 TMDB 换中文译名（复用 360kan 流程的 query_tmdb）；
    -- 未配置 key 或翻译失败不阻断，用原名继续搜（搜索结果自行呈现成败）
    if not is_chinese(name) and type(query_tmdb) == "function"
        and options.tmdb_api_key ~= "" and #Base64.decode(options.tmdb_api_key) >= 32 then
        local title = query_tmdb(name, "tv", menu)
        if title then
            name = title
        end
    end
    search(name)
end

mp.register_script_message("get-tx-event", function(cid, title, year, type_name, video_type)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_anime")
    end

    -- 电影直接加载第一条正片（与 360kan 流程的电影捷径一致；videoType=1 为电影）
    if type_name == "电影" or video_type == "1" then
        show_message("查询弹幕中...", 3)
        fetch_tx_episodes(cid, 1, function(episodes)
            if not episodes or #episodes == 0 then
                show_message("无结果", 3)
                return
            end
            load_tencent_danmaku(cid, episodes[1].vid, 1, title, year, type_name)
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

    fetch_tx_episodes(cid, nil, function(episodes)
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
                title = "第" .. i .. "集",
                hint = ep.title ~= "" and ep.title or nil,
                value = { "script-message-to", mp.get_script_name(), "add-tx-event",
                    cid, ep.vid, tostring(i), title, year, type_name },
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

mp.register_script_message("add-tx-event", function(cid, vid, episodenum, title, year, type_name)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_details")
    end
    load_tencent_danmaku(cid, vid, episodenum, title, year, type_name)
end)
