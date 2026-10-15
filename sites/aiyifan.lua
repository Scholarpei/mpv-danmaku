-- 爱壹帆（yfsp.tv）直连弹幕加载器（App API 逆向链路，签名与接口细节见 modules/aiyifan_parse.lua）
-- 规范源 URL https://www.yfsp.tv/play/{mediaKey}?id={episodeKey}&videoId={uniqueID}&videoType=n
--   （apis/aiyifan_search.lua 产出；站点原生集数链接不带 videoId——用户粘贴时经
--   VideoDetails 接口补齐 uniqueID，每次加载一次轻量 GET，无 AcFun 式映射缓存）
-- 单级磁盘缓存：ayf:{mediaKey}:{videoId} → GetBarrages 原始 JSON（读回走同一 parse 路径）
-- 本文件同时持有 App 签名客户端（密钥引导 + 签名请求）并以全局 ayf_signed_get /
--   ayf_signed_post 暴露给 apis/aiyifan_search.lua（搜索/选集共用同一内存密钥缓存；
--   该文件 require 本模块，main.lua 的 sites require 顺序不受影响）
-- 密钥引导：api/home/config 默认私钥签名、x-pub 空串 → pConfig 密钥对，内存缓存 30 分钟；
--   接口拒绝（ret≠200）时强制刷新密钥重试一次（服务端换钥自适应），网络层失败不重试
-- 网络失败（引导/详情/弹幕任一环节）/接口错误（重试后仍 ret≠200）均走过期缓存兜底
--   （断网可看，OSD「网络失败，已使用过期弹幕缓存」）；成功且非空写缓存，
--   合法空结果（ret=200 且 list=[]，错误 videoId 同口径）不缓存

local msg = require('mp.msg')
local utils = require("mp.utils")
local aparse = require("modules/aiyifan_parse")
local dcache = require("modules/danmaku_cache")

local BASE = "https://api.tripdata.app"
local CONFIG_PATH = "/api/home/config"
local DETAILS_PATH = "/api/Video/VideoDetails"
local BARRAGE_PATH = "/api/Video/GetBarrages"
local CONFIG_TTL = 1800  -- 内存密钥缓存 30 分钟（照 App / danmu_api 口径）

-- App okhttp 拦截器固定头（2026-10-13 实测；App 版本升级可能须同步调整）
local APP_HEADERS = {
    "User-Agent: okhttp-okgo/jeasonlzy",
    "Accept-Language: zh-CN,zh;q=0.8",
    "Lat: 0.0",
    "Lng: 0.0",
    "BundleId: com.cqcsy.ifvod",
    "AppVersion: 1.7.8",
    "System: Android",
    "SystemVersion: 17",
    "DeviceInfo: Xiaomi 23127PN0CC",
    "DeviceId: 2da4a414036a4332782795a031dcab6b4",
    "Version: V3",
    "Lang: 0",
}

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

-- ============ App 签名客户端（apis/aiyifan_search.lua 经全局共用） ============

-- 内存密钥缓存：{ pub, priv, fetched_at }；TTL 内直接复用（二刷/预取零引导请求）
local sign_cfg = nil

-- 引导请求（默认私钥签名、x-pub 空串）→ callback(cfg | nil)；返回取消函数
local function fetch_signing_config(force, callback)
    if not force and sign_cfg and (os.time() - sign_cfg.fetched_at) < CONFIG_TTL then
        callback(sign_cfg)
        return function() end
    end
    local ts = tostring(os.time())
    local query = "_t=" .. ts
    local args = { 'curl', '-L', '-s', '--ssl-no-revoke', '--compressed' }
    for _, h in ipairs(APP_HEADERS) do
        args[#args + 1] = '-H'; args[#args + 1] = h
    end
    args[#args + 1] = '-H'; args[#args + 1] = 'x-timestamp: ' .. ts
    args[#args + 1] = '-H'; args[#args + 1] = 'x-pub: '
    args[#args + 1] = '-H'
    args[#args + 1] = 'x-sign: ' .. aparse.app_sign(query, ts, aparse.DEFAULT_PRIVATE_KEY)
    append_common(args)
    args[#args + 1] = BASE .. CONFIG_PATH .. "?" .. query
    return call_cmd_async_with_timeout(args, 15, function(err, out)
        if err or not out or out == '' then
            msg.warn('爱壹帆签名配置请求失败: ' .. tostring(err))
            callback(nil)
            return
        end
        local parsed = aparse.parse_config(utils.parse_json(out))
        if not parsed.ok then
            msg.warn('爱壹帆签名配置解析失败（pConfig 缺失）')
            callback(nil)
            return
        end
        sign_cfg = { pub = parsed.public_key, priv = parsed.private_key, fetched_at = os.time() }
        msg.verbose('爱壹帆签名配置已更新: ' .. parsed.public_key:sub(1, 12) .. '...')
        callback(sign_cfg)
    end)
end

-- 签名请求：ret≠200 强制刷新密钥重试一次（网络层失败不重试——真断网重试无意义）；
-- callback(响应表 | nil)；返回取消函数（引导与业务请求均可中止）
local function signed_request(method, path, params, body, timeout, callback)
    local cancel_cur = function() end
    local cancel_cfg = function() end

    local function attempt(cfg, fresh)
        local ts = tostring(os.time())
        local query = aparse.build_sign_query(method, params, ts)
        local args = { 'curl', '-L', '-s', '--ssl-no-revoke', '--compressed' }
        for _, h in ipairs(APP_HEADERS) do
            args[#args + 1] = '-H'; args[#args + 1] = h
        end
        args[#args + 1] = '-H'; args[#args + 1] = 'x-timestamp: ' .. ts
        args[#args + 1] = '-H'; args[#args + 1] = 'x-pub: ' .. cfg.pub
        args[#args + 1] = '-H'; args[#args + 1] = 'x-sign: ' .. aparse.app_sign(query, ts, cfg.priv)
        if method == 'POST' then
            args[#args + 1] = '-H'; args[#args + 1] = 'Content-Type: application/json;charset=utf-8'
            args[#args + 1] = '-X'; args[#args + 1] = 'POST'
            args[#args + 1] = '-d'; args[#args + 1] = utils.format_json(body)
        end
        append_common(args)
        args[#args + 1] = BASE .. path .. "?" .. query
        cancel_cur = call_cmd_async_with_timeout(args, timeout or 15, function(err, out)
            if err or not out or out == '' then
                callback(nil)
                return
            end
            local d = utils.parse_json(out)
            if type(d) ~= 'table' then
                msg.warn('爱壹帆接口响应非 JSON: ' .. path)
                callback(nil)
                return
            end
            if d.ret ~= 200 then
                if not fresh then
                    msg.warn('爱壹帆接口拒绝（ret=' .. tostring(d.ret) .. ' '
                        .. tostring(aparse.parse_error_msg(d) or '') .. '），刷新签名配置重试')
                    cancel_cfg = fetch_signing_config(true, function(cfg2)
                        if not cfg2 then
                            callback(nil)
                            return
                        end
                        attempt(cfg2, true)
                    end)
                    return
                end
                msg.warn('爱壹帆接口拒绝（ret=' .. tostring(d.ret) .. ' '
                    .. tostring(aparse.parse_error_msg(d) or '') .. '）')
                callback(nil)
                return
            end
            callback(d)
        end) or cancel_cur
    end

    cancel_cfg = fetch_signing_config(false, function(cfg)
        if not cfg then
            callback(nil)
            return
        end
        attempt(cfg, false)
    end)
    return function()
        cancel_cfg()
        cancel_cur()
    end
end

-- 全局暴露（apis/aiyifan_search.lua 的搜索/选集请求；签名细节不外漏）
function ayf_signed_get(path, params, callback, timeout)
    return signed_request('GET', path, params, nil, timeout, callback)
end

function ayf_signed_post(path, body, callback, timeout)
    return signed_request('POST', path, nil, body, timeout, callback)
end

-- ============ 弹幕加载 ============

-- 从 URL 提取 {media_key, episode_key, video_id, video_type}：
--   /play/{mediaKey}?id=&videoId=&videoType=（多捕获须分开赋值——or 链会截断首值）
-- 站点原生链接（www/m 等子域 /play/{mediaKey}?id={episodeKey}）缺 videoId 由调用方补齐
local function extract_ids(url)
    local u = tostring(url or '')
    local mk = u:match("yfsp%.tv/play/([%w%-_]+)")
    if not mk then return nil end
    return {
        media_key = mk,
        episode_key = u:match("[?&]id=([^&]+)"),
        video_id = u:match("[?&]videoId=([^&]+)"),
        video_type = u:match("[?&]videoType=(%d+)"),
    }
end

local function danmaku_key(media_key, video_id)
    return "ayf:" .. media_key .. ":" .. video_id
end

-- 原始 JSON/缓存载荷 → 解析结果（同一条 parse 路径）
local function parse_payload(payload)
    if type(payload) ~= "string" then return nil end
    local parsed = aparse.parse_danmaku(utils.parse_json(payload))
    if not parsed.ok then return nil end
    return parsed.comments
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

-- 为爱壹帆弹幕源加载弹幕（URL 由 apis/aiyifan_search.lua 产出或用户粘贴播放页地址）
function load_danmaku_for_aiyifan(path, callback)
    callback = callback or function() end
    local url = path or mp.get_property('stream-open-filename', '')
    local ids = extract_ids(url)
    if not ids then
        msg.error('无法从 URL 解析爱壹帆 mediaKey: ' .. tostring(url))
        callback(false, nil, '无法从 URL 解析爱壹帆 mediaKey')
        return
    end

    -- videoId 到手后进缓存三段式（TTL 命中 / 网络 / 过期兜底）
    local function with_video_id(video_id, video_type)
        local key = danmaku_key(ids.media_key, video_id)

        -- 1) TTL 内命中弹幕缓存：不发网络（含签名引导）
        local hit = dcache.get(key)
        if hit then
            local comments = parse_payload(hit.payload)
            if comments and #comments > 0 then
                msg.verbose("弹幕缓存命中：" .. key)
                deliver(url, comments, "cache")
                callback(true)
                return
            end
            dcache.remove(key)
        end

        -- 引导/弹幕网络失败与接口错误（重试后仍 ret≠200）均按网络失败口径走过期兜底
        local function try_stale()
            local stale = dcache.get_stale(key)
            local comments = stale and parse_payload(stale.payload) or nil
            if comments and #comments > 0 then
                deliver(url, comments, "stale")
                callback(true)
            else
                callback(false, nil, '网络失败且无过期缓存')
            end
        end

        -- 2) 拉弹幕（videoId 即选集 uniqueID；videoType 透传选集真实值，正片 1/剧场版 0）
        ayf_signed_get(BARRAGE_PATH, {
            { "mediaKey", ids.media_key },
            { "videoId", video_id },
            { "videoType", video_type },
        }, function(d)
            if d == nil then
                try_stale()
                return
            end
            local comments = aparse.parse_danmaku(d).comments
            if #comments == 0 then
                -- 该集确实无弹幕（合法空结果，错误 videoId 同口径）不缓存
                show_message('好像没有弹幕哦', 3)
                callback(false, nil, '该集无弹幕')
                return
            end
            -- 3) 成功且非空写缓存（原始响应信封）后走原路径
            dcache.put(key, utils.format_json(d), { type = "json", count = #comments })
            deliver(url, comments, nil)
            callback(true)
        end)
    end

    if ids.video_id then
        with_video_id(ids.video_id, ids.video_type or "1")
        return
    end

    -- 站点原生链接缺 videoId：先取详情接口补齐 uniqueID（失败按网络失败口径兜底——
    -- 无 videoId 连缓存键都无从查起，不做过期兜底直接失败）
    if not ids.episode_key then
        msg.error('爱壹帆链接缺 id/videoId 参数: ' .. tostring(url))
        callback(false, nil, '爱壹帆链接缺 id/videoId 参数')
        return
    end
    ayf_signed_get(DETAILS_PATH, {
        { "mediaKey", ids.media_key },
        { "videoType", ids.video_type or "1" },
        { "episodeKey", ids.episode_key },
    }, function(d)
        local parsed = d and aparse.parse_details(d) or nil
        if not parsed or not parsed.ok then
            msg.warn('爱壹帆详情补齐失败（uniqueID 未取到）: ' .. tostring(url))
            callback(false, nil, '详情补齐失败（uniqueID 未取到）')
            return
        end
        with_video_id(parsed.video_id, parsed.video_type)
    end)
end

-- 下一集弹幕预取：按 mediaKey+videoId 拉弹幕写入 ayf: 磁盘缓存（与
-- load_danmaku_for_aiyifan 同键，但不写 sources/不渲染/无 OSD）。TTL 内命中跳过网络；
-- callback(done: boolean)
function prefetch_aiyifan_danmaku(media_key, video_id, video_type, callback)
    callback = callback or function() end
    local key = danmaku_key(media_key, video_id)
    if dcache.get(key) then callback(true) return end
    ayf_signed_get(BARRAGE_PATH, {
        { "mediaKey", media_key },
        { "videoId", video_id },
        { "videoType", video_type or "1" },
    }, function(d)
        -- 与正式路径同口径：网络失败/合法空结果不缓存
        if d == nil then
            callback(false)
            return
        end
        local comments = aparse.parse_danmaku(d).comments
        if #comments == 0 then
            callback(false)
            return
        end
        dcache.put(key, utils.format_json(d), { type = "json", count = #comments })
        callback(true)
    end)
end

require("modules/source_duration").register("yfsp%.tv/play/",function(url,callback)
    local ids=extract_ids(url)
    if not ids then callback(nil);return end
    local function query() require("modules/aiyifan_web").query(ids,callback) end
    if ids.episode_key then query();return end
    ayf_signed_post("/api/Video/VideoChooseGather",{mediaKey=ids.media_key},function(data)
        local parsed=aparse.parse_episodes(data)
        for _,ep in ipairs(parsed.episodes) do
            if (ids.video_id and ep.video_id==ids.video_id)
                or (not ids.video_id and (tonumber(ep.title)==1 or #parsed.episodes==1)) then
                ids.episode_key,ids.video_id=ep.episode_key,ep.video_id
                query();return
            end
        end
        callback(nil,{reason="未能按已匹配视频 ID 定位分集"})
    end)
end)
