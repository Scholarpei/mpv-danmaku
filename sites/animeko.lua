-- animeko（open-ani 社区弹幕）直连加载器
-- 规范源 URL 形如 https://api.animeko.org/episode/<episodeId>（apis/animeko_search.lua 产出）；
--   请求 <node>/v1/danmaku/<episodeId>，节点失败依次降级（api.animeko.org →
--   danmaku-global.myani.org → danmaku-cn.myani.org → s1.animeko.openani.org）
-- 弹幕磁盘缓存（键 ako:{episodeId}）：TTL 内命中零网络；全部节点网络失败回退过期缓存
-- （断网可看）；成功且解析非空写缓存（载荷为原始响应，读回经同一 parse 路径）

local msg = require('mp.msg')
local utils = require("mp.utils")
local aparse = require("modules/animeko_parse")
local dcache = require("modules/danmaku_cache")

local NODES = {
    "https://api.animeko.org",
    "https://danmaku-global.myani.org",
    "https://danmaku-cn.myani.org",
    "https://s1.animeko.openani.org",
}

local USER_AGENT = 'uosc-danmaku/1.0 (mpv danmaku plugin)'

local function build_curl_args(url)
    local args = {
        'curl', '-L', '-s', '--ssl-no-revoke', '--compressed',
        '--user-agent', USER_AGENT,
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
    table.insert(args, url)
    return args
end

-- 从规范 URL 提取 episodeId
local function extract_episode_id(url)
    return tostring(url):match("animeko%.org/episode/(%d+)")
end

local function cache_key(episode_id)
    return "ako:" .. episode_id
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

-- 保存并加载最终弹幕 JSON
local function save_output_and_load(output_table, source_url)
    if #output_table == 0 then
        show_message('未获取到任何弹幕', 3)
        return false
    end
    save_danmaku_json(source_url, utils.format_json(output_table))
    load_danmaku(true, nil, true)
    return true
end

-- 原始响应 → 解析列表（缓存载荷与网络响应同一条 parse 路径）
local function parse_payload(payload)
    if type(payload) ~= "string" then return {} end
    return aparse.parse_danmaku_list(utils.parse_json(payload))
end

-- 节点依次降级拉取原始响应：网络层失败（err/空响应）试下一节点，全败 callback(nil)；
-- 有响应 callback(out)（含合法空结果，由调用方解析判定，不再降级）
local function fetch_raw(episode_id, callback)
    local node_idx = 1

    local function try_node()
        if node_idx > #NODES then
            msg.warn('animeko 全部节点尝试失败 episodeId=' .. episode_id)
            callback(nil)
            return
        end
        local node = NODES[node_idx]
        node_idx = node_idx + 1
        call_cmd_async_with_timeout(build_curl_args(node .. "/v1/danmaku/" .. episode_id),
            15, function(err, out)
                if err or not out or out == '' then
                    msg.warn('animeko 节点请求失败 ' .. node .. ': ' .. tostring(err))
                    try_node()
                    return
                end
                callback(out)
            end)
    end

    try_node()
end

-- 为 animeko 弹幕源加载弹幕
function load_danmaku_for_animeko(path, callback)
    callback = callback or function() end
    local url = path or mp.get_property('stream-open-filename', '')
    local episode_id = extract_episode_id(url or '')
    if not episode_id then
        msg.error('无法从 URL 中解析 animeko episodeId: ' .. tostring(url))
        callback(false)
        return
    end

    local key = cache_key(episode_id)

    -- 1) TTL 内命中缓存：不发网络
    local hit = dcache.get(key)
    if hit then
        local comments = parse_payload(hit.payload)
        if #comments > 0 then
            DANMAKU.cache_hit = "cache"
            msg.verbose("弹幕缓存命中：" .. key)
            callback(save_output_and_load(build_output(comments), url))
            return
        end
        dcache.remove(key)
    end

    fetch_raw(episode_id, function(raw)
        -- 2) 全部节点网络失败 → 过期缓存兜底（断网可看）
        if raw == nil then
            local stale = dcache.get_stale(key)
            local comments = stale and parse_payload(stale.payload) or {}
            if #comments > 0 then
                DANMAKU.cache_hit = "stale"
                show_message("网络失败，已使用过期弹幕缓存", 3)
                callback(save_output_and_load(build_output(comments), url))
            else
                callback(false)
            end
            return
        end
        local comments = parse_payload(raw)
        if #comments == 0 then
            -- 该集确实无弹幕（合法空结果）不缓存
            show_message('好像没有弹幕哦', 3)
            callback(false)
            return
        end
        -- 3) 成功且非空写缓存后走原路径
        dcache.put(key, raw, { type = "json", count = #comments })
        callback(save_output_and_load(build_output(comments), url))
    end)
end

-- 下一集预取：按 episodeId 拉弹幕写入 ako: 磁盘缓存（与 load_danmaku_for_animeko 同键，
-- 但不写 sources/不渲染/无 OSD）。TTL 内命中跳过网络；callback(done: boolean)
function prefetch_animeko_danmaku(episode_id, callback)
    callback = callback or function() end
    episode_id = tostring(episode_id)
    local key = cache_key(episode_id)
    if dcache.get(key) then callback(true) return end

    fetch_raw(episode_id, function(raw)
        -- 与正式路径同口径：网络全败/合法空结果不缓存
        if raw == nil then callback(false) return end
        local comments = parse_payload(raw)
        if #comments == 0 then callback(false) return end
        dcache.put(key, raw, { type = "json", count = #comments })
        callback(true)
    end)
end
