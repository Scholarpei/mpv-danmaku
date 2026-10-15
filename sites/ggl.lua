-- girigirilove（girigiri愛動漫）直连弹幕加载器
-- 规范源 URL 形如 https://ani.girigirilove.com/playGV{GVid}-{线路src}-{集ep}/
--   （apis/ggl_search.lua 产出；海外备用域 girigirilove.icu 与 www. 等子域均认并
--   规范化到 ani.girigirilove.com 取数）
-- 单级磁盘缓存：ggl:{GVid}-{src}-{ep} → getScrolling 原始 JSON（读回走同一 parse 路径）
-- 加载链：TTL 命中零网络直载 → 未命中先取播放页解 player_aaaa 出裸 m3u8
--   （encrypt 0/1/2 三档，实测全站 2=base64+percent）再 POST getScrolling（弹幕接口
--   按资源名模糊匹配，繁/简线路实测同池；缓存键仍带线路 src，防站方后续分池时串台）
--   → 播放页请求失败 / 弹幕网络失败 / 接口错误（code≠1、非 JSON）均 get_stale 过期
--   缓存兜底（断网可看，OSD「网络失败，已使用过期弹幕缓存」）
-- 成功且解析非空写缓存；合法空结果（code=1 且 info=[]，该集确无弹幕）不缓存
-- （合法空与接口错误两口径区分——后者走过期兜底，前者如实提示无弹幕）

local msg = require('mp.msg')
local utils = require("mp.utils")
local gparse = require("modules/ggl_parse")
local dcache = require("modules/danmaku_cache")

local BASE = "https://ani.girigirilove.com"
local PLAY_PAGE = BASE .. "/playGV"
local DANMAKU_API = "https://m3u8.girigirilove.com/api.php/Scrolling/getScrolling"
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

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

-- 从 URL 提取 GVid/线路/集数（girigirilove.com 任意子域与 girigirilove.icu 备用域，
-- 均为 /playGV{gv}-{src}-{ep}/ 路径；⚠️ 多捕获值不可用 or 链回退——or 会把首个 match
-- 截断为单值丢掉后续捕获，须分开赋值，照 sites/acfun.lua extract_ids 口径）
local function extract_ids(url)
    local u = tostring(url or '')
    local gv, src, ep = u:match("girigirilove%.com/playGV(%d+)-(%d+)-(%d+)")
    if not gv then
        gv, src, ep = u:match("girigirilove%.icu/playGV(%d+)-(%d+)-(%d+)")
    end
    return gv, src, ep
end

local function danmaku_key(gv, src, ep)
    return ("ggl:%s-%s-%s"):format(gv, src, ep)
end

-- 原始 JSON/缓存载荷 → 解析结果（同一条 parse 路径）
local function parse_payload(payload)
    if type(payload) ~= "string" then return nil end
    local parsed = gparse.parse_danmaku(payload)
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

-- GET 播放页 HTML：网络层失败/空响应 callback(nil)，有响应 callback(out)
local function fetch_play_page(gv, src, ep, callback)
    local args = {
        'curl', '-L', '-s', '--ssl-no-revoke', '--compressed',
        '--user-agent', UA,
    }
    append_common(args)
    table.insert(args, ("%s%s-%s-%s/"):format(PLAY_PAGE, gv, src, ep))
    call_cmd_async_with_timeout(args, 15, function(err, out)
        if err or not out or out == '' then
            msg.warn('girigirilove 播放页请求失败: ' .. tostring(err))
            callback(nil)
            return
        end
        callback(out)
    end)
end

-- (gv, src, ep) → 裸 m3u8（每次现取播放页解 player_aaaa；无中间缓存——播放页仅一次
-- 轻量 GET，TTL 弹幕缓存命中时整链零网络）。网络/解析失败 callback(nil)
local function resolve_m3u8(gv, src, ep, callback)
    fetch_play_page(gv, src, ep, function(html)
        if not html then
            callback(nil)
            return
        end
        local parsed = gparse.parse_player(html)
        if not parsed.ok then
            msg.warn('girigirilove 播放页解析失败 gv=' .. tostring(gv)
                .. '-' .. tostring(src) .. '-' .. tostring(ep))
            callback(nil)
            return
        end
        callback(parsed.m3u8)
    end)
end

-- POST getScrolling：网络层失败/空响应 callback(nil)，有响应 callback(out)（含合法空）
-- m3u8 已在解析层校验为纯安全 ASCII（无引号/反斜杠），直接拼 JSON body 无需转义
local function fetch_danmaku(m3u8, callback)
    local args = {
        'curl', '-L', '-s', '--ssl-no-revoke', '--compressed',
        '--user-agent', UA,
        '-H', 'Content-Type: application/json',
        '-X', 'POST',
        '-d', '{"play_url":"' .. m3u8 .. '"}',
    }
    append_common(args)
    table.insert(args, DANMAKU_API)
    call_cmd_async_with_timeout(args, 15, function(err, out)
        if err or not out or out == '' then
            msg.warn('girigirilove 弹幕接口请求失败: ' .. tostring(err))
            callback(nil)
            return
        end
        callback(out)
    end)
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

-- 为 girigirilove 弹幕源加载弹幕（URL 由 apis/ggl_search.lua 产出或用户粘贴播放页地址）
function load_danmaku_for_ggl(path, callback)
    callback = callback or function() end
    local url = path or mp.get_property('stream-open-filename', '')
    local gv, src, ep = extract_ids(url)
    if not gv then
        msg.error('无法从 URL 解析 girigirilove 播放页参数: ' .. tostring(url))
        callback(false, nil, '无法从 URL 解析 girigirilove 播放页参数')
        return
    end
    local key = danmaku_key(gv, src, ep)

    -- 1) TTL 内命中弹幕缓存：不发网络
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

    -- 播放页与弹幕接口任一环节失败（含接口错误）均按网络失败口径走过期缓存兜底（断网可看）
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

    -- 2) 先取播放页解裸 m3u8，再 POST 弹幕
    resolve_m3u8(gv, src, ep, function(m3u8)
        if not m3u8 then
            try_stale()
            return
        end
        fetch_danmaku(m3u8, function(raw)
            if raw == nil then
                try_stale()
                return
            end
            local parsed = parse_payload(raw)
            if not parsed then
                -- 接口错误（code≠1 / 非 JSON）同网络失败口径
                msg.warn('girigirilove 弹幕接口返回异常 gv=' .. tostring(gv))
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

-- 下一集弹幕预取：按 (gv, src, ep) 拉弹幕写入 ggl: 磁盘缓存（与 load_danmaku_for_ggl
-- 同键，但不写 sources/不渲染/无 OSD）。TTL 内命中跳过网络；callback(done: boolean)
function prefetch_ggl_danmaku(gv, src, ep, callback)
    callback = callback or function() end
    local key = danmaku_key(gv, src, ep)
    if dcache.get(key) then callback(true) return end
    resolve_m3u8(gv, src, ep, function(m3u8)
        if not m3u8 then
            callback(false)
            return
        end
        fetch_danmaku(m3u8, function(raw)
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

local function query_video_duration(url,callback)
    local gv,src,ep=extract_ids(url)
    if not gv then callback(nil);return end
    resolve_m3u8(gv,src,ep,function(media)
        if not media then callback(nil,{reason="播放页未提供可读取的媒体地址"});return end
        require("modules/media_duration").query(media,function(n,reason) callback(n,{reason=reason}) end)
    end)
end
require("modules/source_duration").register("girigirilove%.com/playGV",query_video_duration)
require("modules/source_duration").register("girigirilove%.icu/playGV",query_video_duration)
