-- 埋堆堆（TVB）直连弹幕加载器
-- 规范源 URL 形如 https://www.mddcloud.com.cn/video/<vodUuid>.html?uuid=<epUuid>
--   （apis/maiduidui_search.lua 产出）；单次 vodBarrage396(times=0) 返回全集弹幕
-- 弹幕磁盘缓存（键 mdd:{epUuid}）：TTL 内命中零网络；网络失败/空响应回退过期缓存
-- （断网可看）；成功且解析非空写缓存（载荷为原始响应，读回经同一 parse 路径）

local msg = require('mp.msg')
local utils = require("mp.utils")
local mparse = require("modules/maiduidui_parse")
local dcache = require("modules/danmaku_cache")

local BASE = "https://mob.mddcloud.com.cn"
local BARRAGE_PATH = "/api/barrage/vodBarrage396.action"

local function build_curl_args(body_json)
    local args = {
        'curl', '-L', '-s', '--ssl-no-revoke', '--compressed',
        '--user-agent', 'Mdd/5.8.00 (Android+32+)',
        '-H', 'Content-Type: application/json',
        '-H', 'version: 5.8.00',
        '-H', 'Referer: https://www.mddcloud.com.cn',
        '-X', 'POST',
        '-d', body_json,
    }
    if options.cookie_file and options.cookie_file ~= '' then
        table.insert(args, '-b')
        table.insert(args, mp.command_native({'expand-path', options.cookie_file}))
    end
    if options.proxy ~= '' then
        table.insert(args, '-x')
        table.insert(args, options.proxy)
    end
    append_curl_timeout(args)
    table.insert(args, BASE .. BARRAGE_PATH)
    return args
end

-- 从规范 URL 提取 vodUuid 与分集 uuid
local function extract_uuids(url)
    local u = tostring(url or '')
    local vod = u:match("mddcloud%.com%.cn/video/([%w]+)%.html")
    local ep = u:match("[?&]uuid=([%w]+)")
    return vod, ep
end

local function cache_key(ep_uuid)
    return "mdd:" .. ep_uuid
end

-- 原始响应 → 解析列表（缓存载荷与网络响应同一条 parse 路径）
local function parse_payload(payload)
    if type(payload) ~= "string" then return {} end
    return mparse.parse_barrage(utils.parse_json(payload))
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

-- 组签名请求体并 POST 拉原始响应：网络层失败/空响应 callback(nil)，有响应 callback(out)
local function fetch_raw(vod_uuid, ep_uuid, callback)
    local time_ms = os.time() * 1000 + math.random(0, 999)
    local data = { sactionUuid = ep_uuid, times = 0, vodUuid = vod_uuid }
    local sign = mparse.sign(BARRAGE_PATH, data, time_ms)
    local body = mparse.wrap_body(data, time_ms, sign)

    call_cmd_async_with_timeout(build_curl_args(utils.format_json(body)), 15,
        function(err, out)
            if err or not out or out == '' then
                msg.warn('埋堆堆弹幕请求失败: ' .. tostring(err))
                callback(nil)
                return
            end
            callback(out)
        end)
end

-- 为埋堆堆弹幕源加载弹幕
function load_danmaku_for_maiduidui(path, callback)
    callback = callback or function() end
    local url = path or mp.get_property('stream-open-filename', '')
    local vod_uuid, ep_uuid = extract_uuids(url)
    if not vod_uuid or not ep_uuid then
        msg.error('无法从 URL 解析埋堆堆 vodUuid/分集uuid: ' .. tostring(url))
        callback(false, nil, '无法从 URL 解析埋堆堆 vodUuid/分集uuid')
        return
    end

    local key = cache_key(ep_uuid)

    -- 1) TTL 内命中缓存：不发网络
    local hit = dcache.get(key)
    if hit then
        local comments = parse_payload(hit.payload)
        if #comments > 0 then
            source_status.note_cache(url, "cache")
            msg.verbose("弹幕缓存命中：" .. key)
            save_danmaku_json(url, utils.format_json(build_output(comments)))
            load_danmaku(true, nil, true)
            callback(true)
            return
        end
        dcache.remove(key)
    end

    fetch_raw(vod_uuid, ep_uuid, function(raw)
        -- 2) 网络失败/空响应 → 过期缓存兜底（断网可看）
        if raw == nil then
            local stale = dcache.get_stale(key)
            local comments = stale and parse_payload(stale.payload) or {}
            if #comments > 0 then
                source_status.note_cache(url, "stale")
                show_message("网络失败，已使用过期弹幕缓存", 3)
                save_danmaku_json(url, utils.format_json(build_output(comments)))
                load_danmaku(true, nil, true)
                callback(true)
            else
                callback(false, nil, '网络失败且无过期缓存')
            end
            return
        end
        local comments = parse_payload(raw)
        if #comments == 0 then
            -- 该集确实无弹幕（合法空结果）不缓存
            show_message('好像没有弹幕哦', 3)
            callback(false, nil, '该集无弹幕')
            return
        end
        -- 3) 成功且非空写缓存后走原路径
        dcache.put(key, raw, { type = "json", count = #comments })
        save_danmaku_json(url, utils.format_json(build_output(comments)))
        load_danmaku(true, nil, true)
        callback(true)
    end)
end

-- 下一集预取：按分集 uuid 拉弹幕写入 mdd: 磁盘缓存（与 load_danmaku_for_maiduidui 同键，
-- 但不写 sources/不渲染/无 OSD）。TTL 内命中跳过网络；callback(done: boolean)
function prefetch_maiduidui_danmaku(vod_uuid, ep_uuid, callback)
    callback = callback or function() end
    local key = cache_key(ep_uuid)
    if dcache.get(key) then callback(true) return end

    fetch_raw(vod_uuid, ep_uuid, function(raw)
        -- 与正式路径同口径：网络失败/合法空结果不缓存
        if raw == nil then callback(false) return end
        local comments = parse_payload(raw)
        if #comments == 0 then callback(false) return end
        dcache.put(key, raw, { type = "json", count = #comments })
        callback(true)
    end)
end
