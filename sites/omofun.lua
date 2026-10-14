-- OmoFun（Lanerc）直连弹幕加载器（App API 逆向链路，签名/解密/接口细节见
-- modules/omofun_parse.lua；2026-10-14/15 全链路线上实测 + 真机 HAR 复核口径）
-- 规范源 URL https://lanerc.life/vod/{vod_id}/{集序号}（apis/omofun_search.lua 产出；
--   lanerc.life 为旧 API 后端域名的固定标识域，与运行时发现的实际 API 域名解耦
--   ——站方换域名时历史 URL 仍可续载，加载经 DoH TXT 发现链自动跟随）
-- 单级磁盘缓存：omf:{vod_id}-{集序号} → barragev2 解密后明文 JSON（读回走同一
--   parse 路径）。⚠️ 缓存键用 (vod_id, 集序号)——TTL 命中直接由 URL 参数组键
--   零网络（域名发现/详情定位全部跳过，断网二刷零请求），续载/预取/换集全同键
-- 弹幕参数语义（2026-10-15 真机 HAR 实锤）：barragev2?vid={番剧 vod_id}&vod=
--   {集序号}——vid 即搜索/详情用的 vod_id、vod 即选集数组序号（1 起），弹幕侧
--   不需要 app/v2/play 的 resource_id→流解析（play 响应为 protobuf 流 token，
--   与弹幕无关；报告「vid 由 resource_id 经 play 解析」的推断有误）。实测各集
--   弹量独立（芙莉莲 ep1/ep2/ep28 = 694KB/283KB/1MB），越界集序号返回空数组
-- 加载链：TTL 命中零网络直载 → 未命中经域名发现（DoH TXT dohx.lanerc.moe，
--   会话内存缓存；失败用内置兜底 base）→ 详情选集定位（会话缓存）→ GET
--   barragev2 → 任一环节网络失败/接口错误（code≠201/200、data 空、解密失败、
--   非 JSON）均 get_stale 过期缓存兜底（断网可看，OSD「网络失败，已使用过期弹幕缓存」）
-- 成功且解析非空写缓存；合法空结果（该集无弹幕/集序号越界同口径：code=201 +
-- 空数组）不缓存；详情取到但目标集越界（老历史超出集数）为确定性无弹幕
--   callback(false, true) 不消费过期缓存（与 ezdmw/cyc no_data 同口径）
-- 鉴权：无——全弹幕侧接口实测无 token 可访问（真机 HAR 仅 UA/content-type/
--   accept-encoding 三头，Authorization 未发送）；服务端当前亦不校验签名
--   （坏签名/无签名实测放行，仍照 App 真机形态发送）
-- 本文件持有签名客户端（域名发现 + 签名请求 + 信封解密）并以全局 omf_signed_get /
--   fetch_omofun_detail 暴露给 apis/omofun_search.lua（require 本模块共用同一份
--   内存状态；main.lua 的 sites require 顺序不受影响）

local msg = require('mp.msg')
local utils = require("mp.utils")
local oparse = require("modules/omofun_parse")
local dcache = require("modules/danmaku_cache")

-- 公共 DoH JSON API（doh.pub 为 App 实际使用的公共 DoH；阿里兜底）
local DOH_RESOLVERS = { "https://doh.pub/resolve", "https://223.5.5.5/resolve" }
local BARRAGE_PATH = "app/chat/barragev2"
local DETAIL_FMT = "app/v2/vod/%s"
-- 真机 HAR 实测三头（均不参与签名）
local APP_HEADERS = {
    "User-Agent: Dart/3.9.2 (dart:io)",
    "Content-Type: application/json; charset=utf-8",
    "Accept-Encoding: gzip",
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

-- ============ 签名客户端（apis/omofun_search.lua 经全局共用） ============

-- 会话态：API base（DoH TXT 发现结果）、详情会话缓存
local api_base = nil
local cached_details = {}

-- 基础 GET（无签名语义，DoH 探测用）：网络层失败/空响应 callback(nil)
local function raw_get(url, headers, timeout, callback)
    local args = { 'curl', '-L', '-s', '--ssl-no-revoke', '--compressed' }
    for _, h in ipairs(headers or {}) do
        args[#args + 1] = '-H'; args[#args + 1] = h
    end
    append_common(args)
    args[#args + 1] = url
    return call_cmd_async_with_timeout(args, timeout, function(err, out)
        if err or not out or out == '' then
            callback(nil)
            return
        end
        callback(out)
    end)
end

-- API base 解析（会话内存缓存）：公共 DoH 查 dohx.lanerc.moe TXT（两解析器串行）
-- → AES 解密 → 完整 URL；全失败用内置兜底 base（与当前 TXT 值一致）。
-- TXT 即权威发现（App 冷启动链实测），不做 health 探测——请求本身即验证
local function resolve_api_base(callback)
    if api_base then
        callback(api_base)
        return
    end
    local function try(i)
        if i > #DOH_RESOLVERS then
            msg.verbose('OmoFun DoH TXT 发现失败，用内置兜底 base')
            api_base = oparse.FALLBACK_API_BASE
            callback(api_base)
            return
        end
        raw_get(DOH_RESOLVERS[i] .. "?name=" .. oparse.TXT_DOMAIN .. "&type=16",
            { "Accept: application/json" }, 6, function(out)
            local base = nil
            local d = out and utils.parse_json(out) or nil
            if type(d) == "table" and type(d.Answer) == "table" then
                for _, a in ipairs(d.Answer) do
                    if a.type == 16 and type(a.data) == "string" then
                        base = oparse.decrypt_domain_txt(a.data)
                        if base then break end
                    end
                end
            end
            if base then
                api_base = base
                msg.verbose('OmoFun API base: ' .. base)
                callback(base)
                return
            end
            try(i + 1)
        end)
    end
    try(1)
end

-- 签名 GET：callback(解密后业务表 | nil)；返回取消函数。网络失败 / 非 JSON /
-- code≠201/200 / data 空 / 解密失败 / 明文非 JSON 均 callback(nil)。
-- params 为有序数组 {{k, v}, …}（nil 项跳过）
local function signed_get(path, params, callback, timeout)
    local cancel_cur = function() end
    resolve_api_base(function(base)
        local ts = os.time()
        local sign = oparse.sign_general(path, ts, oparse.nonce())
        local parts = {}
        for _, kv in ipairs(params or {}) do
            if kv[2] ~= nil then
                parts[#parts + 1] = tostring(kv[1]) .. "=" .. tostring(kv[2])
            end
        end
        parts[#parts + 1] = "sign=" .. sign
        local args = { 'curl', '-L', '-s', '--ssl-no-revoke', '--compressed' }
        for _, h in ipairs(APP_HEADERS) do
            args[#args + 1] = '-H'; args[#args + 1] = h
        end
        append_common(args)
        args[#args + 1] = base .. "/" .. path .. "?" .. table.concat(parts, "&")
        cancel_cur = call_cmd_async_with_timeout(args, timeout or 15, function(err, out)
            if err or not out or out == '' then
                callback(nil)
                return
            end
            local env = oparse.parse_envelope(out)
            if not env.ok then
                msg.warn('OmoFun 接口失败: ' .. path .. ' code=' .. tostring(env.code)
                    .. ' msg=' .. tostring(env.msg))
                callback(nil)
                return
            end
            callback(env.payload)
        end) or cancel_cur
    end)
    return function() cancel_cur() end
end

-- 全局暴露（apis/omofun_search.lua 的搜索/详情请求；签名与发现细节不外漏）
function omf_signed_get(path, params, callback, timeout)
    return signed_get(path, params, callback, timeout)
end

-- ============ 详情选集 ============

-- 详情选集表（会话内存缓存，同番换集/续载/预取零重复拉取）：
-- vod_id → { episodes={ {resource_id, title} }, count, vod_name, year, total }；
-- 网络失败/接口错误/解析失败/无选集 callback(nil)（resource_id 仅为选集身份
-- 透传，弹幕定位用集序号不需要它）
function fetch_omofun_detail(vod_id, callback)
    vod_id = tostring(vod_id or '')
    local hit = cached_details[vod_id]
    if hit then
        callback(hit)
        return
    end
    signed_get(DETAIL_FMT:format(vod_id), nil, function(payload)
        if payload == nil then
            msg.warn('OmoFun 详情请求失败 vod_id=' .. vod_id)
            callback(nil)
            return
        end
        local parsed = oparse.parse_detail(payload)
        if not parsed.ok or parsed.count == 0 then
            msg.warn('OmoFun 详情无选集 vod_id=' .. vod_id)
            callback(nil)
            return
        end
        local entry = { episodes = parsed.episodes, count = parsed.count,
            vod_name = parsed.vod_name, year = parsed.year, total = parsed.total }
        cached_details[vod_id] = entry
        callback(entry)
    end, 15)
end

-- ============ 弹幕加载 ============

-- 从 URL 提取 (vod_id, 集序号)：/vod/{vod_id}/{ep}（query 参数天然不参与匹配）
local function extract_ids(url)
    local u = tostring(url or '')
    return u:match("lanerc%.life/vod/(%d+)/(%d+)")
end

local function danmaku_key(vod_id, ep)
    return ("omf:%s-%s"):format(vod_id, ep)
end

-- 集序号（从 1 起）→ 选集条目；越界 nil
local function locate_episode(entry, ep)
    local idx = tonumber(ep)
    if not idx or idx < 1 or idx > #entry.episodes then return nil end
    return entry.episodes[idx]
end

-- 解密后明文表/缓存载荷 → 弹幕解析结果（同一条 parse 路径）
local function parse_payload_table(payload)
    local parsed = oparse.parse_danmaku(payload)
    if not parsed.ok then return nil end
    return parsed
end

local function parse_payload_json(payload)
    if type(payload) ~= "string" then return nil end
    return parse_payload_table(utils.parse_json(payload))
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

-- 为 OmoFun 弹幕源加载弹幕（URL 由 apis/omofun_search.lua 产出）
function load_danmaku_for_omofun(path, callback)
    callback = callback or function() end
    local url = path or mp.get_property('stream-open-filename', '')
    local vod_id, ep = extract_ids(url)
    if not vod_id then
        msg.error('无法从 URL 解析 OmoFun 播放参数: ' .. tostring(url))
        callback(false, nil, '无法从 URL 解析 OmoFun 播放参数')
        return
    end
    local key = danmaku_key(vod_id, ep)

    -- 1) TTL 内命中弹幕缓存：不发网络（域名发现/详情定位全部跳过）
    local hit = dcache.get(key)
    if hit then
        local parsed = parse_payload_json(hit.payload)
        if parsed and #parsed.comments > 0 then
            msg.verbose("弹幕缓存命中：" .. key)
            deliver(url, parsed.comments, "cache")
            callback(true)
            return
        end
        dcache.remove(key)
    end

    -- 发现/详情/弹幕任一环节失败（含接口错误与解密失败）均按网络失败口径走
    -- 过期缓存兜底（断网可看）
    local function try_stale()
        local stale = dcache.get_stale(key)
        local parsed = stale and parse_payload_json(stale.payload) or nil
        if parsed and #parsed.comments > 0 then
            deliver(url, parsed.comments, "stale")
            callback(true)
        else
            callback(false, nil, '网络失败且无过期缓存')
        end
    end

    -- 2) 取详情定位目标集（集序号即弹幕 vod 参数——真机 HAR 实锤口径），再 GET 弹幕
    fetch_omofun_detail(vod_id, function(entry)
        if not entry then
            try_stale()
            return
        end
        local target = locate_episode(entry, ep)
        if not target then
            -- 详情取到了但目标集不存在（老历史超出集数等）：确定性无弹幕，
            -- 不消费过期缓存也不走 dmku 兜底（dmku 不会有 lanerc.life 数据）
            callback(false, true, ('第 %s 集｜共 %s 集'):format(ep, entry.count))
            return
        end
        signed_get(BARRAGE_PATH, {
            { "vid", vod_id },
            { "vod", ep },
        }, function(payload)
            if payload == nil then
                try_stale()
                return
            end
            local parsed = parse_payload_table(payload)
            if not parsed.ok then
                msg.warn('OmoFun 弹幕明文解析异常 vod_id=' .. vod_id .. ' ep=' .. ep)
                try_stale()
                return
            end
            if #parsed.comments == 0 then
                -- 该集确实无弹幕（集序号越界与无弹幕同口径的合法空）不缓存
                show_message('好像没有弹幕哦', 3)
                callback(false, nil, '该集无弹幕')
                return
            end
            -- 3) 成功且非空写缓存（解密后明文，体积减半且不含密钥依赖）
            dcache.put(key, utils.format_json(payload),
                { type = "json", count = #parsed.comments })
            deliver(url, parsed.comments, nil)
            callback(true)
        end, 15)
    end)
end

-- 下一集弹幕预取：按 (vod_id, 集序号) 拉弹幕写入 omf: 磁盘缓存（与
-- load_danmaku_for_omofun 同键，但不写 sources/不渲染/无 OSD）。TTL 内命中跳过
-- 网络；callback(done: boolean)
function prefetch_omofun_danmaku(vod_id, ep, callback)
    callback = callback or function() end
    local key = danmaku_key(vod_id, ep)
    if dcache.get(key) then callback(true) return end
    fetch_omofun_detail(vod_id, function(entry)
        local target = entry and locate_episode(entry, ep) or nil
        if not target then
            callback(false)
            return
        end
        signed_get(BARRAGE_PATH, {
            { "vid", tostring(vod_id) },
            { "vod", tostring(ep) },
        }, function(payload)
            -- 与正式路径同口径：网络失败/接口错误/合法空结果均不缓存
            local parsed = payload and parse_payload_table(payload) or nil
            if not parsed or #parsed.comments == 0 then
                callback(false)
                return
            end
            dcache.put(key, utils.format_json(payload),
                { type = "json", count = #parsed.comments })
            callback(true)
        end, 15)
    end)
end

-- 测试后门：重置全部会话态（仅 sites_cache_test 调用；运行时无人触碰）
function omf_debug_reset()
    api_base = nil
    cached_details = {}
end
