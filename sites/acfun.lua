-- AcFun（A站）直连弹幕加载器
-- 规范源 URL 形如 https://www.acfun.cn/v/ac{ac号}?part={n}（apis/acfun_search.lua 产出；
-- 合集分P每P独立 ac号 part=1，多P视频同 ac号按 part 序）
-- 两级磁盘缓存：
--   acfmap:{ac号}:{part} → {video_id} 页面解析映射（弹弹 resourceId 与 URL 无关，必须先解析页面；
--     命中可免整页抓取，二刷零网络的关键）
--   acf:{videoId} → 聚合弹幕载荷（与网络响应同构，读回经同一 parse 路径）
-- 弹幕分页：POST new-danmaku/list 响应 pcursor 为下一页游标（"no_more" 即止，实测首页 0 → "2"）；
--   任一页网络失败整体视为失败（防半截弹幕被 TTL 缓存固化），走过期缓存兜底（断网可看）
-- 成功且解析非空写缓存；合法空结果（该视频确无弹幕）不缓存

local msg = require('mp.msg')
local utils = require("mp.utils")
local aparse = require("modules/acfun_parse")
local dcache = require("modules/danmaku_cache")

local BASE = "https://www.acfun.cn"
local VIDEO_PAGE = BASE .. "/v/ac"
local DANMAKU_PATH = "/rest/pc-direct/new-danmaku/list"
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
local MAX_PAGES = 40 -- 分页保险丝（lifegpc/bli 同款上限；289 条实测 2 页）

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

-- 从规范 URL 提取 ac号 与 part（part 缺省 1）
local function extract_ids(url)
    local u = tostring(url or '')
    local ac = u:match("acfun%.cn/v/ac(%d+)")
    local part = tonumber(u:match("[?&]part=(%d+)")) or 1
    return ac, part
end

local function map_key(ac_id, part)
    return ("acfmap:%s:%d"):format(ac_id, part)
end

local function danmaku_key(video_id)
    return "acf:" .. video_id
end

-- 原始响应/缓存载荷 → 解析结果（同一条 parse 路径）
local function parse_payload(payload)
    if type(payload) ~= "string" then return nil end
    return aparse.parse_danmaku(utils.parse_json(payload))
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

-- GET 视频页 HTML：网络层失败/空响应 callback(nil)，有响应 callback(out)
local function fetch_video_page(ac_id, callback)
    local args = {
        'curl', '-L', '-s', '--ssl-no-revoke', '--compressed',
        '--user-agent', UA,
        '-H', 'Referer: ' .. BASE .. '/',
    }
    append_common(args)
    table.insert(args, VIDEO_PAGE .. ac_id)
    call_cmd_async_with_timeout(args, 15, function(err, out)
        if err or not out or out == '' then
            msg.warn('AcFun 视频页请求失败: ' .. tostring(err))
            callback(nil)
            return
        end
        callback(out)
    end)
end

-- ac号+part → videoId（先查映射缓存，miss 抓页面解析后写映射）
-- callback(video_id, from_cache)：失败 callback(nil, false)
local function resolve_video_id(ac_id, part, callback)
    local mkey = map_key(ac_id, part)
    local hit = dcache.get(mkey)
    if hit then
        local obj = utils.parse_json(hit.payload)
        if obj and obj.video_id and obj.video_id ~= "" then
            callback(obj.video_id, true)
            return
        end
        dcache.remove(mkey)
    end

    fetch_video_page(ac_id, function(html)
        if not html then
            -- 网络失败 → 过期映射缓存兜底（映射过期但弹幕缓存仍可用时保住断网可看链路）
            local stale = dcache.get_stale(mkey)
            local sobj = stale and utils.parse_json(stale.payload)
            if sobj and sobj.video_id and sobj.video_id ~= "" then
                msg.verbose("AcFun 映射缓存过期兜底：" .. mkey)
                callback(sobj.video_id, false)
                return
            end
            callback(nil, false)
            return
        end
        local parsed = aparse.parse_video_page(html)
        local v = parsed.videos and parsed.videos[part] or parsed.videos and parsed.videos[1]
        if not parsed.ok or not v then
            msg.warn('AcFun 视频页解析失败 ac=' .. tostring(ac_id) .. ' part=' .. tostring(part))
            callback(nil, false)
            return
        end
        dcache.put(mkey, utils.format_json({ video_id = v.video_id, title = v.title }), { type = "json" })
        callback(v.video_id, false)
    end)
end

-- POST 单页弹幕：网络层失败/空响应 callback(nil)，有响应 callback(out)
local function fetch_danmaku_page(video_id, pcursor, callback)
    local form = ("resourceId=%s&resourceType=9&enableAdvanced=true&pcursor=%s&count=200&sortType=1&asc=false")
        :format(video_id, pcursor)
    local args = {
        'curl', '-L', '-s', '--ssl-no-revoke', '--compressed',
        '--user-agent', UA,
        '-H', 'Referer: ' .. BASE .. '/',
        '-H', 'Content-Type: application/x-www-form-urlencoded',
        '-X', 'POST',
        '-d', form,
    }
    append_common(args)
    table.insert(args, BASE .. DANMAKU_PATH)
    call_cmd_async_with_timeout(args, 15, function(err, out)
        if err or not out or out == '' then
            callback(nil)
            return
        end
        callback(out)
    end)
end

-- 分页拉全量弹幕：callback(comments)（任一页网络/接口失败 callback(nil)）
local function fetch_all_danmaku(video_id, callback)
    local all = {}
    local pcursor, pages = "0", 0

    local function step()
        if pcursor == nil or pages >= MAX_PAGES then
            callback(all)
            return
        end
        fetch_danmaku_page(video_id, pcursor, function(raw)
            if raw == nil then
                msg.warn('AcFun 弹幕分页请求失败 videoId=' .. tostring(video_id) .. ' pcursor=' .. tostring(pcursor))
                callback(nil)
                return
            end
            local parsed = parse_payload(raw)
            if not parsed.ok then
                msg.warn('AcFun 弹幕接口返回异常 videoId=' .. tostring(video_id))
                callback(nil)
                return
            end
            for _, c in ipairs(parsed.comments) do
                all[#all + 1] = c
            end
            pcursor = parsed.pcursor
            pages = pages + 1
            step()
        end)
    end

    step()
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

-- 为 AcFun 弹幕源加载弹幕（URL 由 apis/acfun_search.lua 产出或用户粘贴播放页地址）
function load_danmaku_for_acfun(path, callback)
    callback = callback or function() end
    local url = path or mp.get_property('stream-open-filename', '')
    local ac_id, part = extract_ids(url)
    if not ac_id then
        msg.error('无法从 URL 解析 AcFun ac号: ' .. tostring(url))
        callback(false, nil, '无法从 URL 解析 AcFun ac号')
        return
    end

    resolve_video_id(ac_id, part, function(video_id)
        if not video_id then
            callback(false, nil, 'videoId 解析失败（映射与视频页解析均未命中）')
            return
        end
        local key = danmaku_key(video_id)

        -- 1) TTL 内命中弹幕缓存：不发网络
        local hit = dcache.get(key)
        if hit then
            local parsed = parse_payload(hit.payload)
            if parsed.ok and #parsed.comments > 0 then
                msg.verbose("弹幕缓存命中：" .. key)
                deliver(url, parsed.comments, "cache")
                callback(true)
                return
            end
            dcache.remove(key)
        end

        fetch_all_danmaku(video_id, function(comments)
            -- 2) 网络失败 → 过期缓存兜底（断网可看）
            if comments == nil then
                local stale = dcache.get_stale(key)
                local parsed = stale and parse_payload(stale.payload)
                if parsed and #parsed.comments > 0 then
                    deliver(url, parsed.comments, "stale")
                    callback(true)
                else
                    callback(false, nil, '网络失败且无过期缓存')
                end
                return
            end
            if #comments == 0 then
                -- 该视频确实无弹幕（合法空结果）不缓存
                show_message('好像没有弹幕哦', 3)
                callback(false, nil, '该集无弹幕')
                return
            end
            -- 3) 成功且非空写缓存后走原路径
            dcache.put(key, aparse.build_cache_payload(comments), { type = "json", count = #comments })
            deliver(url, comments, nil)
            callback(true)
        end)
    end)
end

-- 下一集弹幕预取：按 ac号+part 拉弹幕写入 acf: 磁盘缓存（与 load_danmaku_for_acfun 同键，
-- 但不写 sources/不渲染/无 OSD）。映射/弹幕 TTL 内命中跳过网络；callback(done: boolean)
function prefetch_acfun_danmaku(ac_id, part, callback)
    callback = callback or function() end
    resolve_video_id(ac_id, part, function(video_id)
        if not video_id then
            callback(false)
            return
        end
        local key = danmaku_key(video_id)
        local hit = dcache.get(key)
        if hit then callback(true) return end
        fetch_all_danmaku(video_id, function(comments)
            -- 与正式路径同口径：网络失败/合法空结果不缓存
            if comments == nil or #comments == 0 then
                callback(false)
                return
            end
            dcache.put(key, aparse.build_cache_payload(comments), { type = "json", count = #comments })
            callback(true)
        end)
    end)
end
