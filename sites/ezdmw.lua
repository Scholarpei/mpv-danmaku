-- ezdmw（E站弹幕网）直连弹幕加载器
-- 规范源 URL 形如 https://www.ezdmw.org/Index/video/{videoId}.html（apis/ezdmw_search.lua
-- 产出；ezdmw.com 域 301 到 .org，两种写法均认）
-- 单级磁盘缓存：ezd:{videoId} → getData 原始 XML（B站标准格式，读回走同一 parse 路径；
--   弹幕资源名 nk 与 videoId 一一对应，无需 AcFun 式页面映射缓存）
-- sign 每请求轮换（实测两次连抓同一播放页即不同）且不可缓存：每次加载先取播放页提取
--   新 nk+sign 再取弹幕；播放页网络失败走过期缓存兜底（断网可看）
-- ⚠️ 播放页取到但无弹幕播放器 iframe（第三方解析源，圣诞之吻SS 实测）= E站未给该集绑
--   弹幕资源，确定性无弹幕：如实提示、不消费过期缓存、回调带 no_data 判定（调度层
--   跳过 dmku 兜底——dmku 只按主流站点 URL 索引，永远不会有 ezdmw.org 数据）
-- 弹幕接口双域：主域 player.ezdmw.com，备用域 player.danmuzf.vip 同路径降级（animeko
--   节点降级范本）；任一域有响应即用，全败走过期缓存兜底（断网可看）
-- 成功且解析非空写缓存；合法空结果（该集确无弹幕）不缓存、同样带 no_data 判定

local msg = require('mp.msg')
local utils = require("mp.utils")
local eparse = require("modules/ezdmw_parse")
local dcache = require("modules/danmaku_cache")

local BASE = "https://www.ezdmw.org"
local VIDEO_PAGE = BASE .. "/Index/video/"
-- 弹幕接口双域（主域失败依次降级；getData 路径两域同构，实测载荷一致）
local DANMAKU_HOSTS = { "https://player.ezdmw.com", "https://player.danmuzf.vip" }
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

-- 从 URL 提取 videoId（ezdmw.org / ezdmw.com 两种域，均 /Index/video/{videoId}.html）
local function extract_video_id(url)
    local u = tostring(url or '')
    return u:match("ezdmw%.org/Index/video/(%d+)")
        or u:match("ezdmw%.com/Index/video/(%d+)")
end

local function danmaku_key(video_id)
    return "ezd:" .. video_id
end

-- 原始 XML/缓存载荷 → 解析结果（同一条 parse 路径）
local function parse_payload(payload)
    if type(payload) ~= "string" then return nil end
    local parsed = eparse.parse_danmaku(payload)
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

-- GET 播放页 HTML：网络层失败/空响应 callback(nil)，有响应 callback(out)
local function fetch_player_page(video_id, callback)
    local args = {
        'curl', '-L', '-s', '--ssl-no-revoke', '--compressed',
        '--user-agent', UA,
    }
    append_common(args)
    table.insert(args, VIDEO_PAGE .. video_id .. ".html")
    call_cmd_async_with_timeout(args, 15, function(err, out)
        if err or not out or out == '' then
            msg.warn('ezdmw 播放页请求失败: ' .. tostring(err))
            callback(nil)
            return
        end
        callback(out)
    end)
end

-- videoId → {nk, sign}（每次现取播放页：sign 每请求轮换不可缓存）
-- 网络失败 callback(nil)；页面取到但无弹幕播放器 iframe callback({no_player=true})
-- （第三方解析源，E站未绑弹幕资源——确定性无弹幕，调用方按 no_data 口径处理）
local function resolve_nk_sign(video_id, callback)
    fetch_player_page(video_id, function(html)
        if not html then
            callback(nil)
            return
        end
        local parsed = eparse.parse_player(html)
        if not parsed.ok then
            msg.warn('ezdmw 播放页无弹幕播放器 videoId=' .. tostring(video_id))
            callback({ no_player = true })
            return
        end
        callback(parsed)
    end)
end

-- getData 请求 URL（nk 原样拼入——实测含 / 不编码服务端即收；getUser=游客 URL 编码字面量）
local function danmaku_url(host, nk, sign)
    return ("%s/index/getData.html?video_id=%s&json=xml&danmu=%s&sign=%s"
        .. "&timeAxis=false&getUser=%%E6%%B8%%B8%%E5%%AE%%A2"):format(host, nk, nk, sign)
end

-- 双域依次降级拉弹幕 XML：网络层失败（err/空响应）试下一域，全败 callback(nil)；
-- 有响应 callback(out)（含合法空，由调用方解析判定，不再降级）
local function fetch_danmaku(nk, sign, callback)
    local idx = 1

    local function try_host()
        if idx > #DANMAKU_HOSTS then
            msg.warn('ezdmw 弹幕接口全部域名尝试失败 nk=' .. tostring(nk))
            callback(nil)
            return
        end
        local host = DANMAKU_HOSTS[idx]
        idx = idx + 1
        local args = {
            'curl', '-L', '-s', '--ssl-no-revoke', '--compressed',
            '--user-agent', UA,
        }
        append_common(args)
        table.insert(args, danmaku_url(host, nk, sign))
        call_cmd_async_with_timeout(args, 15, function(err, out)
            if err or not out or out == '' then
                msg.warn('ezdmw 弹幕接口请求失败 ' .. host .. ': ' .. tostring(err))
                try_host()
                return
            end
            callback(out)
        end)
    end

    try_host()
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

-- 为 ezdmw 弹幕源加载弹幕（URL 由 apis/ezdmw_search.lua 产出或用户粘贴播放页地址）
function load_danmaku_for_ezdmw(path, callback)
    callback = callback or function() end
    local url = path or mp.get_property('stream-open-filename', '')
    local video_id = extract_video_id(url)
    if not video_id then
        msg.error('无法从 URL 解析 ezdmw videoId: ' .. tostring(url))
        callback(false, nil, '无法从 URL 解析 ezdmw videoId')
        return
    end
    local key = danmaku_key(video_id)

    -- 1) TTL 内命中弹幕缓存：不发网络
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

    -- 播放页与弹幕接口任一环节失败均按网络失败口径走过期缓存兜底（断网可看）
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

    -- 2) 先取播放页拿新 nk+sign（sign 每请求轮换），再取弹幕
    resolve_nk_sign(video_id, function(info)
        if not info then
            try_stale()
            return
        end
        if info.no_player then
            -- 播放页取到但无弹幕播放器：E站未给该集绑弹幕资源（第三方解析源），
            -- 确定性无弹幕——如实提示，不消费过期缓存（弹幕资源都不会有）
            show_message('E站该集无弹幕资源', 3)
            callback(false, true, '该集无弹幕资源（E站未绑定弹幕播放器）')
            return
        end
        fetch_danmaku(info.nk, info.sign, function(raw)
            if raw == nil then
                try_stale()
                return
            end
            local comments = parse_payload(raw) or {}
            if #comments == 0 then
                -- 该集确实无弹幕（合法空结果）不缓存；no_data 判定供调度层跳过 dmku 兜底
                show_message('好像没有弹幕哦', 3)
                callback(false, true, '该集无弹幕')
                return
            end
            -- 3) 成功且非空写缓存（原始 XML）后走原路径
            dcache.put(key, raw, { type = "xml", count = #comments })
            deliver(url, comments, nil)
            callback(true)
        end)
    end)
end

-- 下一集弹幕预取：按 videoId 拉弹幕写入 ezd: 磁盘缓存（与 load_danmaku_for_ezdmw 同键，
-- 但不写 sources/不渲染/无 OSD）。TTL 内命中跳过网络；callback(done: boolean)
function prefetch_ezdmw_danmaku(video_id, callback)
    callback = callback or function() end
    local key = danmaku_key(video_id)
    if dcache.get(key) then callback(true) return end
    resolve_nk_sign(video_id, function(info)
        if not info or info.no_player then
            -- 无弹幕播放器同网络失败口径：不写缓存即失败（加载路径由用户侧如实提示）
            callback(false)
            return
        end
        fetch_danmaku(info.nk, info.sign, function(raw)
            -- 与正式路径同口径：网络失败/合法空结果不缓存
            if raw == nil then
                callback(false)
                return
            end
            local comments = parse_payload(raw) or {}
            if #comments == 0 then
                callback(false)
                return
            end
            dcache.put(key, raw, { type = "xml", count = #comments })
            callback(true)
        end)
    end)
end
