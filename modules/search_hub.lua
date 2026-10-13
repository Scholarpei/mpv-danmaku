-- 多源聚合搜索 hub（纯关键词搜索的并发编排与分组渲染）
-- 纯关键词 → dandanplay(全部 api_server) + 腾讯 + 360kan（+ 已配置的 maccms）并发搜索，
--   结果按固定顺序分组渲染进 menu_anime：空结果组隐藏、失败组显示一行错误、整体 10s 到点齐展示。
-- 后缀 |tx/|mac/|ds 等单源流程不走此文件（仍在各 api 模块内）；@备注 仅作用于 dandanplay 组。
-- 取消：菜单关闭 → cancel-active-request → set_active_request 注册的 cancel_all；
--   迟到回调由 session.aborted / task.done 双 guard 丢弃。
--
-- dandanplay 组用 /api/v2/search/episodes?anime=&v2=true 取代 /api/v2/search/anime 搜索：
--   v2 端点无 25 条结果上限（官方语义，Kazumi/animeko 等客户端同款用法），hasMore=true 表示
--   结果集被截断（该端点无翻页参数，只能收窄关键词，分组尾部出一行提示）。
--   兼容性：端点并非所有 api_server 都放行（默认代理 danmaku-api.152468.xyz 白名单未含，
--   返回 404 "Unsupported API"；自建 danmu-api 已实现；官方直连需注册凭证）。故按服务器
--   探测 + 会话级能力记忆：未知/已支持的服务器先打 v2 端点，响应形状明确不支持（合法 JSON
--   但无 animes/hasMore 键）才标记不支持并即时回退旧端点重试该服务器——网络失败/超时不算
--   不支持证据（只影响本次、不下结论），默认代理用户仅首次搜索多一次 404 往返。
--   v2 响应内嵌的 episodes[] 有意不用（选集恒走 /bangumi/{id}，保持与旧端点同一流程——
--   官方语义下内嵌列表可能截断，且聚合菜单内嵌集数会显著膨胀菜单 JSON）。

local msg = require("mp.msg")
local utils = require("mp.utils")

local M = {}

M.MENU_TYPE = "menu_anime"
local MENU_TITLE = "在此处输入番剧名称"
local FOOTNOTE = "使用enter或ctrl+enter进行搜索"

M.HUB_DEADLINE = 10        -- 聚合整体时限：到点渲染已到结果，未完成组标「超时」
M.PER_SOURCE_TIMEOUT = 9   -- 单源内部请求超时（须小于 HUB_DEADLINE）

M.GROUP_ORDER = { "dandanplay", "tencent", "kan360", "maccms", "youku", "iqiyi", "mgtv", "bilibili",
    "bahamut", "animeko", "maiduidui", "acf", "ezd", "ggl", "ayf" }
local GROUP_LABEL = {
    dandanplay = "dandanplay",
    tencent = "腾讯",
    kan360 = "360kan",
    maccms = "maccms",
    youku = "优酷",
    iqiyi = "爱奇艺",
    mgtv = "芒果",
    bilibili = "bilibili",
    bahamut = "巴哈姆特",
    animeko = "animeko",
    maiduidui = "埋堆堆",
    acf = "AcFun",
    ezd = "ezdmw",
    ggl = "girigirilove",
    ayf = "爱壹帆",
}

-- ============ 纯函数（构建分组菜单条目；单测直打，不触碰 mp.*） ============

-- 分组头：不可选中、加粗、居中（uosc 无真分组头，沿 menu.lua 假标题行惯例）
function M.group_header(label)
    return {
        title = "── " .. label .. " ──",
        bold = true,
        selectable = false,
        keep_open = true,
        align = "center",
    }
end

-- 失败组错误行：斜体灰显，占住组位（区别「没结果」与「搜不了」）
function M.error_row(text)
    return {
        title = text,
        italic = true,
        muted = true,
        selectable = false,
        keep_open = true,
        align = "center",
    }
end

-- 整体无结果行（沿 menu.lua 既有「无结果」惯例）
function M.empty_overall_row()
    return {
        title = "无结果",
        value = "",
        italic = true,
        keep_open = true,
        selectable = false,
        align = "center",
    }
end

-- dandanplay v2 搜索 hasMore=true 时的组内尾部提示行（结果被截断、无翻页参数）
function M.truncation_row()
    return {
        title = "ⓘ 结果过多已截断，可细化关键词",
        value = "",
        italic = true,
        muted = true,
        keep_open = true,
        selectable = false,
        align = "center",
    }
end

-- /api/v2/search/episodes（v2）或 /api/v2/search/anime（旧）响应解析与归一（纯函数）
-- 两端点响应同构度足够共用：判定「支持」看形状（合法表且含 animes 或 hasMore 键）——
--   默认代理对白名单外端点回 {"success":false,"errorMessage":"Unsupported API"}（无两键）→ 不支持。
-- 归一为旧端点条目形状：bangumiId 统一取 anime.bangumiId 或 anime.animeId（v2 只有 animeId，
--   两值在弹弹play语义下相同）并 tostring——menu.lua embed_episodes 的 value[5] == 集数消息参数
--   （恒字符串）匹配依赖两侧同为字符串；typeDescription/type 透传供菜单 hint。
-- 返回 { supported=bool, animes={...}, has_more=bool }；条目缺 animeTitle 或缺两 id 整条跳过。
function M.parse_search_episodes(d)
    local result = { supported = false, animes = {}, has_more = false }
    if type(d) ~= "table" then return result end
    if d.animes == nil and d.hasMore == nil then return result end
    result.supported = true
    result.has_more = d.hasMore == true
    if type(d.animes) ~= "table" then return result end
    for _, anime in ipairs(d.animes) do
        if type(anime) == "table" and anime.animeTitle ~= nil
            and (anime.bangumiId ~= nil or anime.animeId ~= nil) then
            result.animes[#result.animes + 1] = {
                animeTitle = anime.animeTitle,
                bangumiId = tostring(anime.bangumiId or anime.animeId),
                typeDescription = anime.typeDescription,
                type = anime.type,
            }
        end
    end
    return result
end

-- 等待期进度行：必须位于 items[1] 且 italic+icon=spinner，
-- 供 menu.lua strip_loading_from_latest_menu_anime 识别剥离
function M.progress_row(title)
    return {
        title = title,
        value = "",
        italic = true,
        keep_open = true,
        selectable = false,
        icon = "spinner",
        align = "center",
    }
end

-- results: { [key] = {items={...}} 或 {err="..."} }；nil 的 key 整组跳过（源未参与）。
-- 规则：err 组=组头+错误行；空 items 组整组隐藏（连组头都不出）；全空 → 单行「无结果」；
--   has_more=true（dandanplay v2 搜索截断）在组内条目后追加一行提示。
function M.build_grouped_items(results)
    local out = {}
    for _, key in ipairs(M.GROUP_ORDER) do
        local r = results[key]
        if r ~= nil then
            if r.err ~= nil then
                out[#out + 1] = M.group_header(GROUP_LABEL[key])
                out[#out + 1] = M.error_row(r.err)
            elseif r.items ~= nil and #r.items > 0 then
                out[#out + 1] = M.group_header(GROUP_LABEL[key])
                for _, it in ipairs(r.items) do
                    out[#out + 1] = it
                end
                if r.has_more then
                    out[#out + 1] = M.truncation_row()
                end
            end
        end
    end
    if #out == 0 then
        return { M.empty_overall_row() }
    end
    return out
end

-- states: { [key] = {status="pending"|"done"|"error", count=n(完成时),
--                     done=n, total=n(dandanplay 局部进度)} }；nil 的 key 不显示。
-- 例：「聚合搜索中 dandanplay 2/3｜腾讯 ✓ 5条｜360kan 搜索中｜maccms ✗」
function M.progress_title(states)
    local parts = {}
    for _, key in ipairs(M.GROUP_ORDER) do
        local st = states[key]
        if st ~= nil then
            local seg
            if st.status == "done" then
                seg = "✓ " .. tostring(st.count or 0) .. "条"
            elseif st.status == "error" then
                seg = "✗"
            elseif st.total ~= nil then
                seg = tostring(st.done or 0) .. "/" .. tostring(st.total)
            else
                seg = "搜索中"
            end
            parts[#parts + 1] = GROUP_LABEL[key] .. " " .. seg
        end
    end
    return "聚合搜索中 " .. table.concat(parts, "｜")
end

-- ============ 取数适配器 ============

-- dandanplay /search/episodes 服务器能力记忆（模块级会话缓存）：url -> true|false，nil=未探测。
-- 仅在确定性证据下标记：响应为合法 JSON 且含 animes/hasMore 键 → true；合法 JSON 但缺两键
-- （如默认代理的 "Unsupported API"）→ false。网络失败/超时不标记——只影响本次搜索。
local episodes_capability = {}

-- dandanplay 组：全部 api_server 并发（沿旧 get_animes 的扇出/跨服务器去重/配置顺序拼接语义）。
-- 端点选择见文件头：未探测/已支持的服务器打 /search/episodes?anime=&v2=true，已确认不支持
-- （或本轮探测失败回退）的打 /search/anime?keyword=；探测不支持即时发起旧端点回退轮。
-- sink: { progress(done, total), done(result) }；result 为 {items=, has_more=} 或 {err=}；
--   返回取消函数（取消全部在途轮，回退轮不再发起）。
function M.start_dandan_search(query, server_metas, sink)
    local servers, notes = {}, {}
    for _, m in ipairs(server_metas) do
        servers[#servers + 1] = m.url
        if m.note and m.note ~= "" then
            notes[m.url] = m.note
        end
    end

    local encoded = url_encode(query)

    local buckets, seen = {}, {}
    local err_count, done_count, total = 0, 0, 0
    local has_more = false
    local aborted = false
    local active_cancels, active_rounds = {}, 0

    local function add_animes(server, animes)
        for _, anime in ipairs(animes) do
            local key = anime.bangumiId
                or (anime.animeTitle and anime.animeTitle:gsub("%s+", " ") or nil)
            if key and not seen[key] then
                seen[key] = true
                buckets[server] = buckets[server] or {}
                buckets[server][#buckets[server] + 1] =
                    build_dandanplay_menu_item(anime, server, notes[server])
            end
        end
    end

    local function finish()
        if aborted then return end
        -- 按配置的 server 顺序拼接（与旧 get_animes 终版一致）
        local items = {}
        for _, srv in ipairs(servers) do
            for _, it in ipairs(buckets[srv] or {}) do
                items[#items + 1] = it
            end
        end
        -- 全部请求（含回退轮）皆网络失败才报「请求失败」；形状不支持但服务器活着不在此列
        if #items == 0 and #servers > 0 and total > 0 and err_count == total then
            sink.done({ err = "请求失败" })
        else
            sink.done({ items = items, has_more = has_more })
        end
    end

    -- 一轮并发请求；round_servers 用同一端点。use_episodes 决定端点与不支持时的回退排队。
    local function run_round(round_servers, use_episodes)
        total = total + #round_servers
        local fallback_queue = {}

        local function build_args(server)
            local url
            if use_episodes then
                url = server .. "/api/v2/search/episodes?anime=" .. encoded .. "&v2=true"
            else
                url = server .. "/api/v2/search/anime?keyword=" .. encoded
            end
            return make_danmaku_request_args("GET", url)
        end

        active_rounds = active_rounds + 1
        local round_cancel = parallel_requests(round_servers, build_args,
            function(server, err, out)
                done_count = done_count + 1
                if err == nil then
                    local parsed = M.parse_search_episodes(utils.parse_json(out))
                    if parsed.supported then
                        if use_episodes then
                            episodes_capability[server] = true
                        end
                        if parsed.has_more then has_more = true end
                        add_animes(server, parsed.animes)
                    elseif use_episodes then
                        -- 形状明确不支持（非网络失败）：记能力、排旧端点回退轮
                        episodes_capability[server] = false
                        fallback_queue[#fallback_queue + 1] = server
                    end
                    -- 旧端点响应形状不完整：与旧行为一致——贡献零条目、不计错误
                else
                    -- 网络失败：不算不支持证据（不标能力），v2 探测轮也不回退——
                    -- 服务器已不可达时再打一轮只会白等（整体「请求失败」口径见 finish）
                    err_count = err_count + 1
                end
                sink.progress(done_count, total)
            end,
            function()
                active_rounds = active_rounds - 1
                if aborted then return end
                if #fallback_queue > 0 then
                    run_round(fallback_queue, false)
                elseif active_rounds == 0 then
                    finish()
                end
            end,
            { concurrency = 5, per_request_timeout = M.PER_SOURCE_TIMEOUT })

        active_cancels[#active_cancels + 1] = round_cancel
    end

    -- 初始轮按能力分拣：已确认不支持 → 直接旧端点；其余（未知/已支持）→ v2 端点
    local probe, legacy = {}, {}
    for _, srv in ipairs(servers) do
        if episodes_capability[srv] == false then
            legacy[#legacy + 1] = srv
        else
            probe[#probe + 1] = srv
        end
    end
    if #probe > 0 then run_round(probe, true) end
    if #legacy > 0 then run_round(legacy, false) end
    if #probe == 0 and #legacy == 0 then finish() end

    return function()
        aborted = true
        for _, c in ipairs(active_cancels) do
            pcall(c)
        end
    end
end

-- ============ 编排 ============

-- 纯关键词聚合搜索入口（menu.lua 的 search-anime-event 无后缀分支调入）
function M.multi_source_search(query, filter_note)
    if not query or query:gsub("%s", "") == "" then
        local cmd = { "script-message-to", mp.get_script_name(), "search-anime-event" }
        update_menu_uosc(M.MENU_TYPE, MENU_TITLE, "请输入搜索内容", FOOTNOTE, cmd, query)
        return
    end

    -- dandanplay 服务器解析（@备注 过滤语义与旧 get_animes 一致：命中取首个匹配，不命中警告后用全部）
    local all_metas = get_api_server_list(options.api_server, true)
    local server_metas = all_metas
    local note_hint = ""
    if filter_note and filter_note ~= "" then
        local matched = {}
        for _, m in ipairs(all_metas) do
            if m.note and m.note == filter_note then
                matched[#matched + 1] = m
            end
        end
        if #matched > 0 then
            server_metas = { matched[1] }
            note_hint = "服务器【" .. filter_note .. "】"
        else
            show_message("未找到备注为【" .. filter_note .. "】的服务器，将使用全部服务器", 3)
            msg.info("未找到备注为【" .. filter_note .. "】的服务器，将使用全部服务器")
        end
    end

    -- 非中文关键词先经 TMDB 换中文译名（silent：失败不渲染菜单只记日志）；
    -- 译名喂腾讯/360kan/maccms，dandanplay 恒用原词（与旧单源行为一致）
    local zh_name = query
    if not is_chinese(query) and type(query_tmdb) == "function"
        and options.tmdb_api_key ~= "" and #Base64.decode(options.tmdb_api_key) >= 32 then
        local t = query_tmdb(query, "tv", nil, true)
        if t then
            zh_name = t
        end
    end

    local menu_cmd = { "script-message-to", mp.get_script_name(), "search-anime-event" }
    local close_cmd = { "script-message-to", mp.get_script_name(), "cancel-active-request", M.MENU_TYPE }

    local session = {
        aborted = false,
        finished = false,
        timer = nil,
        tasks = {},
        query = query,
        note_hint = note_hint,
    }

    local function all_done()
        for _, t in ipairs(session.tasks) do
            if not t.done then return false end
        end
        return true
    end

    local function collect_states()
        local states = {}
        for _, t in ipairs(session.tasks) do
            if t.done then
                if t.result and t.result.err ~= nil then
                    states[t.key] = { status = "error" }
                else
                    states[t.key] = { status = "done",
                        count = t.result and #(t.result.items or {}) or 0 }
                end
            elseif t.progress then
                states[t.key] = { status = "pending",
                    done = t.progress.done, total = t.progress.total }
            else
                states[t.key] = { status = "pending" }
            end
        end
        return states
    end

    -- 前向声明（add_task 的 sink 闭包引用二者；必须在 add_task 定义前声明才是 upvalue）
    local refresh_progress
    local finalize

    local function add_task(key, start_fn)
        local task = { key = key, done = false, result = nil, cancel = nil, progress = nil }
        task.start = function()
            task.cancel = start_fn({
                progress = function(done, total)
                    if session.aborted or session.finished or task.done then return end
                    task.progress = { done = done, total = total }
                    refresh_progress()
                end,
                done = function(result)
                    if session.aborted or session.finished or task.done then return end
                    task.done = true
                    task.result = result
                    task.progress = nil
                    if all_done() then
                        finalize()
                    else
                        refresh_progress()
                    end
                end,
            })
        end
        session.tasks[#session.tasks + 1] = task
    end

    -- 等待期进度刷新（单行 spinner，节奏同旧（n/N）更新）
    refresh_progress = function()
        if session.aborted or session.finished or not uosc_available then return end
        local title = M.progress_title(collect_states())
        if session.note_hint ~= "" then
            title = session.note_hint .. title
        end
        update_menu_uosc(M.MENU_TYPE, MENU_TITLE, { M.progress_row(title) },
            FOOTNOTE, menu_cmd, query, nil, close_cmd)
    end

    -- 终版渲染（幂等：任务全齐或 10s 兜底先到者生效；未完成任务杀掉并标「超时」）
    finalize = function()
        if session.finished or session.aborted then return end
        session.finished = true
        if session.timer then
            session.timer:kill()
            session.timer = nil
        end

        local results = {}
        for _, t in ipairs(session.tasks) do
            if not t.done then
                if t.cancel then pcall(t.cancel) end
                t.result = { err = "超时" }
            end
            results[t.key] = t.result
        end

        local items = M.build_grouped_items(results)
        set_active_request(nil, nil)

        if uosc_available then
            -- 终版不传 on_close（无在途请求，与旧终版一致）；latest_menu_anime 供「↩️ 返回搜索结果」
            latest_menu_anime = update_menu_uosc(M.MENU_TYPE, MENU_TITLE, items,
                FOOTNOTE, menu_cmd, query)
        else
            latest_menu_anime = utils.format_json(items)
            local has_selectable = false
            for _, it in ipairs(items) do
                if it.selectable ~= false then has_selectable = true break end
            end
            if input_loaded and has_selectable then
                show_message("", 0)
                input.terminate()
                mp.add_timeout(0.1, function()
                    open_menu_select(items)
                end)
            else
                show_message("无结果", 3)
            end
        end
    end

    -- 复合取消：杀兜底定时器与全部在途请求；迟到回调由 aborted/done 双 guard 丢弃
    local function cancel_all()
        if session.aborted or session.finished then return end
        session.aborted = true
        if session.timer then
            session.timer:kill()
            session.timer = nil
        end
        for _, t in ipairs(session.tasks) do
            if not t.done and t.cancel then
                pcall(t.cancel)
            end
        end
    end

    -- 组装任务（固定顺序 dandanplay → 腾讯 → 360kan → maccms）
    if #server_metas > 0 then
        add_task("dandanplay", function(sink)
            return M.start_dandan_search(query, server_metas, sink)
        end)
    end
    add_task("tencent", function(sink)
        return fetch_tencent_search(zh_name, function(items, err)
            sink.done(err ~= nil and { err = err } or { items = items or {} })
        end, M.PER_SOURCE_TIMEOUT)
    end)
    add_task("kan360", function(sink)
        -- 沿用 query_extra 的年份尾巴剥离（如「柯南 (1996)」→「柯南」）
        local kw = zh_name:gsub("%s*%(%d-%)%s*$", "")
        return fetch_360kan_search(kw, nil, function(items, err)
            sink.done(err ~= nil and { err = err } or { items = items or {} })
        end, M.PER_SOURCE_TIMEOUT)
    end)
    if #get_api_server_list(options.maccms_servers) > 0 then
        add_task("maccms", function(sink)
            return fetch_maccms_found(zh_name, function(found, all_failed)
                if all_failed then
                    sink.done({ err = "请求失败" })
                else
                    sink.done({ items = build_maccms_items(found or {}) })
                end
            end, { concurrency = 3, per_request_timeout = M.PER_SOURCE_TIMEOUT })
        end)
    end
    add_task("youku", function(sink)
        return fetch_youku_search(zh_name, function(items, err)
            sink.done(err ~= nil and { err = err } or { items = items or {} })
        end, M.PER_SOURCE_TIMEOUT)
    end)
    add_task("iqiyi", function(sink)
        return fetch_iqiyi_search(zh_name, function(items, err)
            sink.done(err ~= nil and { err = err } or { items = items or {} })
        end, M.PER_SOURCE_TIMEOUT)
    end)
    add_task("mgtv", function(sink)
        return fetch_mgtv_search(zh_name, function(items, err)
            sink.done(err ~= nil and { err = err } or { items = items or {} })
        end, M.PER_SOURCE_TIMEOUT)
    end)
    add_task("bilibili", function(sink)
        return fetch_bilibili_search(zh_name, function(items, err)
            sink.done(err ~= nil and { err = err } or { items = items or {} })
        end, M.PER_SOURCE_TIMEOUT)
    end)
    add_task("bahamut", function(sink)
        return fetch_bahamut_search(zh_name, function(items, err)
            sink.done(err ~= nil and { err = err } or { items = items or {} })
        end, M.PER_SOURCE_TIMEOUT)
    end)
    add_task("animeko", function(sink)
        return fetch_animeko_search(zh_name, function(items, err)
            sink.done(err ~= nil and { err = err } or { items = items or {} })
        end, M.PER_SOURCE_TIMEOUT)
    end)
    add_task("maiduidui", function(sink)
        return fetch_maiduidui_search(zh_name, function(items, err)
            sink.done(err ~= nil and { err = err } or { items = items or {} })
        end, M.PER_SOURCE_TIMEOUT)
    end)
    add_task("acf", function(sink)
        return fetch_acfun_search(zh_name, function(items, err)
            sink.done(err ~= nil and { err = err } or { items = items or {} })
        end, M.PER_SOURCE_TIMEOUT)
    end)
    add_task("ezd", function(sink)
        return fetch_ezdmw_search(zh_name, function(items, err)
            sink.done(err ~= nil and { err = err } or { items = items or {} })
        end, M.PER_SOURCE_TIMEOUT)
    end)
    add_task("ggl", function(sink)
        return fetch_ggl_search(zh_name, function(items, err)
            sink.done(err ~= nil and { err = err } or { items = items or {} })
        end, M.PER_SOURCE_TIMEOUT)
    end)
    add_task("ayf", function(sink)
        return fetch_aiyifan_search(zh_name, function(items, err)
            sink.done(err ~= nil and { err = err } or { items = items or {} })
        end, M.PER_SOURCE_TIMEOUT)
    end)

    -- 打开 loading 菜单并注册取消（on_close 走 update_menu_uosc 第 8 参；
    -- 先注册再开菜单，避免菜单刚开就被关闭时漏挂取消）
    set_active_request(cancel_all, M.MENU_TYPE)
    local initial_title = M.progress_title(collect_states())
    if note_hint ~= "" then
        initial_title = note_hint .. initial_title
    end
    if uosc_available then
        update_menu_uosc(M.MENU_TYPE, MENU_TITLE, { M.progress_row(initial_title) },
            FOOTNOTE, menu_cmd, query, nil, close_cmd)
    else
        show_message(initial_title, 30)
    end

    -- 并发启动全部任务（全 callback 化，mpv 事件循环天然并发）+ 整体时限兜底
    for _, t in ipairs(session.tasks) do
        t.start()
    end
    if not all_done() then
        session.timer = mp.add_timeout(M.HUB_DEADLINE, finalize)
    else
        finalize()
    end
end

return M
