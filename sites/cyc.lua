-- 次元城（CYCity）直连弹幕加载器
-- 规范源 URL 形如 https://www.cycani.org/anime/{video_id}/play/{集序号}
--   （apis/cyc_search.lua 产出，与网页原生 URL 同形态——网页带 ?from= 查询参数，
--   提取时路径匹配天然忽略 query；用户粘贴网页地址同样可加载）
-- 单级磁盘缓存：cyc:{video_id}-{集序号} → /api/sections/{sid}/danmaku 原始 JSON
--   （读回走同一 parse 路径）。⚠️ 缓存键用 (video_id, 集序号) 而非 section_id——
--   TTL 命中直接由 URL 参数组键零网络（section_id 仅 miss 时经分集表定位），
--   续载/预取/换集全同键
-- 分集表（video_id → sections 列表）为会话级内存缓存：同番换集/续载/预取零重复
--   拉取；长番（海贼王 1155 集）按 page_size=100（接口上限，网页前端用 48）串行翻页
--   取满 pager.total
-- 加载链：TTL 命中零网络直载 → 未命中取分集表定位 section_id 再 GET 弹幕
--   → 分集表网络失败 / 弹幕网络失败 / 接口错误（code≠0、非 JSON）均 get_stale
--   过期缓存兜底（断网可看，OSD「网络失败，已使用过期弹幕缓存」）
-- 成功且解析非空写缓存；合法空结果（code=0 且 items=[]，该集确无弹幕）不缓存
--   （合法空与接口错误两口径区分——后者走过期兜底，前者如实提示无弹幕）
-- 接口详情与域名轮换史见 modules/cyc_parse.lua 头注释

local msg = require('mp.msg')
local utils = require("mp.utils")
local cparse = require("modules/cyc_parse")
local dcache = require("modules/danmaku_cache")

local BASE = "https://www.cycani.org"
local SECTIONS_API = BASE .. "/api/videos/%s/sections?player_code=cychub&page=%d&page_size=100"
local DANMAKU_API = BASE .. "/api/sections/%s/danmaku"
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
-- 接口唯一必需头（modules/cyc_parse.lua 头注释实测）
local APP_HEADER = { 'x-app-name', 'cyc_web' }
-- 分集翻页保险上限（50 页 × 100 = 5000 集，海贼王级长番 12 页）
local MAX_SECTION_PAGES = 50

local function append_common(args)
    if options.cookie_file and options.cookie_file ~= '' then
        table.insert(args, '-b')
        table.insert(args, mp.command_native({ 'expand-path', options.cookie_file }))
    end
    if options.proxy ~= '' then
        table.insert(args, '-x')
        table.insert(args, options.proxy)
    end
    append_curl_timeout(args)
end

-- 从 URL 提取 (video_id, 集序号)（cycani.org 任意子域，/anime/{vid}/play/{ep} 路径；
-- query 的 ?from= 等参数天然不参与匹配）
local function extract_ids(url)
    local u = tostring(url or '')
    return u:match("cycani%.org/anime/(%d+)/play/(%d+)")
end

local function danmaku_key(vid, ep)
    return ("cyc:%s-%s"):format(vid, ep)
end

-- ============ 分集表（会话级缓存 + 串行翻页） ============

-- 分集表会话缓存：video_id → { episodes={ {id, title} }, total }
local cached_sections = {}

-- GET 单页分集表：网络层失败/空响应 callback(nil)，有响应 callback(out)
local function fetch_sections_page(vid, page, callback)
    local args = {
        'curl', '-L', '-s', '--ssl-no-revoke', '--compressed',
        '--user-agent', UA,
        '-H', APP_HEADER[1] .. ': ' .. APP_HEADER[2],
    }
    append_common(args)
    table.insert(args, SECTIONS_API:format(vid, page))
    call_cmd_async_with_timeout(args, 15, function(err, out)
        if err or not out or out == '' then
            msg.warn('次元城分集表请求失败 vid=' .. tostring(vid) .. ' page=' .. tostring(page)
                .. ': ' .. tostring(err))
            callback(nil)
            return
        end
        callback(out)
    end)
end

-- video_id → 完整分集表 { episodes={ {id, title} }, total }（会话缓存命中零网络；
-- 长番按 pager.total 串行翻页取满）。任何一页网络/解析失败 callback(nil)（整体失败，
-- 不交付半截表——选集定位错位比失败更糟）
function fetch_cyc_sections(vid, callback)
    vid = tostring(vid or '')
    local hit = cached_sections[vid]
    if hit then
        callback(hit)
        return
    end
    local episodes, total = {}, 0
    local page = 1
    local function next_page()
        if page > MAX_SECTION_PAGES then
            msg.warn('次元城分集表翻页超上限 vid=' .. vid)
            callback(nil)
            return
        end
        fetch_sections_page(vid, page, function(raw)
            if not raw then
                callback(nil)
                return
            end
            local parsed = cparse.parse_sections(raw)
            if not parsed.ok then
                msg.warn('次元城分集表解析失败 vid=' .. vid .. ' page=' .. page)
                callback(nil)
                return
            end
            for _, e in ipairs(parsed.list) do
                episodes[#episodes + 1] = e
            end
            total = parsed.total
            if #episodes >= total or #parsed.list == 0 then
                local entry = { episodes = episodes, total = total }
                cached_sections[vid] = entry
                callback(entry)
                return
            end
            page = page + 1
            next_page()
        end)
    end
    next_page()
end

-- 集序号（URL/extra 记录的 play/{n}，从 1 起）→ 分集表条目；越界 nil
local function locate_episode(entry, ep)
    local idx = tonumber(ep)
    if not idx or idx < 1 or idx > #entry.episodes then return nil end
    return entry.episodes[idx]
end

-- ============ 弹幕接口 ============

-- GET 弹幕：网络层失败/空响应 callback(nil)，有响应 callback(out)（含合法空）
local function fetch_danmaku(sid, callback)
    local args = {
        'curl', '-L', '-s', '--ssl-no-revoke', '--compressed',
        '--user-agent', UA,
        '-H', APP_HEADER[1] .. ': ' .. APP_HEADER[2],
    }
    append_common(args)
    table.insert(args, DANMAKU_API:format(sid))
    call_cmd_async_with_timeout(args, 15, function(err, out)
        if err or not out or out == '' then
            msg.warn('次元城弹幕接口请求失败 sid=' .. tostring(sid) .. ': ' .. tostring(err))
            callback(nil)
            return
        end
        callback(out)
    end)
end

-- 原始 JSON/缓存载荷 → 解析结果（同一条 parse 路径）
local function parse_payload(payload)
    if type(payload) ~= "string" then return nil end
    local parsed = cparse.parse_danmaku(payload)
    if not parsed.ok then return nil end
    return parsed
end

-- 解析结果 → 保存载荷（{c="time,color,mode,25,,,", m=text} 约定与其他 sites 加载器一致）
local function build_output(comments)
    local output_table = {}
    for _, c in ipairs(comments) do
        output_table[#output_table + 1] = {
            c = string.format('%s,%s,%s,25,,,', c.time, c.color, c.mode),
            m = c.text,
        }
    end
    return output_table
end

-- 落源 + 渲染（缓存命中/网络成功/过期兜底三路共用）
local function deliver(url, comments, hit_kind)
    if hit_kind then
        source_status.note_cache(url, hit_kind)
        if hit_kind == "stale" then
            show_message("网络失败，已使用过期弹幕缓存", 3)
        end
    end
    save_danmaku_json(url, utils.format_json(build_output(comments)))
    load_danmaku(true, nil, true)
end

-- 为次元城弹幕源加载弹幕（URL 由 apis/cyc_search.lua 产出或用户粘贴网页播放地址）
function load_danmaku_for_cyc(path, callback)
    callback = callback or function() end
    local url = path or mp.get_property('stream-open-filename', '')
    local vid, ep = extract_ids(url)
    if not vid then
        msg.error('无法从 URL 解析次元城播放页参数: ' .. tostring(url))
        callback(false, nil, '无法从 URL 解析次元城播放页参数')
        return
    end
    local key = danmaku_key(vid, ep)

    -- 1) TTL 内命中弹幕缓存：不发网络（分集表也不需要——缓存键由 URL 参数直出）
    local hit = dcache.get(key)
    if hit then
        local parsed = parse_payload(hit.payload)
        if parsed and #parsed.comments > 0 then
            msg.verbose("弹幕缓存命中：" .. key)
            deliver(url, parsed.comments, "cache")
            callback(true)
            return
        end
        dcache.remove(key)
    end

    -- 分集表与弹幕接口任一环节失败（含接口错误）均按网络失败口径走过期缓存兜底（断网可看）
    local function try_stale()
        local stale = dcache.get_stale(key)
        local parsed = stale and parse_payload(stale.payload) or nil
        if parsed and #parsed.comments > 0 then
            deliver(url, parsed.comments, "stale")
            callback(true)
        else
            callback(false, nil, '网络失败且无过期缓存')
        end
    end

    -- 2) 取分集表定位 section_id，再 GET 弹幕
    fetch_cyc_sections(vid, function(entry)
        if not entry then
            -- 分集表网络/解析失败：与弹幕接口失败同口径走过期缓存兜底
            try_stale()
            return
        end
        local target = locate_episode(entry, ep)
        if not target then
            -- 分集表拿到了但目标集不存在（老历史超出集数等）：确定性无弹幕，
            -- 不消费过期缓存也不走 dmku 兜底（dmku 不会有 cycani.org 数据）
            callback(false, true, ('第 %s 集｜共 %s 集'):format(ep, entry.total))
            return
        end
        fetch_danmaku(target.id, function(raw)
            if raw == nil then
                try_stale()
                return
            end
            local parsed = parse_payload(raw)
            if not parsed then
                -- 接口错误（code≠0 / 非 JSON）同网络失败口径
                msg.warn('次元城弹幕接口返回异常 vid=' .. vid .. ' ep=' .. ep)
                try_stale()
                return
            end
            if #parsed.comments == 0 then
                -- 该集确实无弹幕（合法空结果）不缓存
                show_message('好像没有弹幕哦', 3)
                callback(false, nil, '该集无弹幕')
                return
            end
            -- 3) 成功且非空写缓存（原始 JSON）后走原路径
            dcache.put(key, raw, { type = "json", count = #parsed.comments })
            deliver(url, parsed.comments, nil)
            callback(true)
        end)
    end)
end

-- 下一集弹幕预取：按 (video_id, 集序号) 拉弹幕写入 cyc: 磁盘缓存（与
-- load_danmaku_for_cyc 同键，但不写 sources/不渲染/无 OSD）。TTL 内命中跳过网络；
-- callback(done: boolean)
function prefetch_cyc_danmaku(vid, ep, callback)
    callback = callback or function() end
    local key = danmaku_key(vid, ep)
    if dcache.get(key) then callback(true) return end
    fetch_cyc_sections(vid, function(entry)
        local target = entry and locate_episode(entry, ep) or nil
        if not target then
            callback(false)
            return
        end
        fetch_danmaku(target.id, function(raw)
            -- 与正式路径同口径：网络失败/接口错误/合法空结果均不缓存
            local parsed = raw and parse_payload(raw) or nil
            if not parsed or #parsed.comments == 0 then
                callback(false)
                return
            end
            dcache.put(key, raw, { type = "json", count = #parsed.comments })
            callback(true)
        end)
    end)
end
