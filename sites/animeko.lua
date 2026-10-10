-- animeko（open-ani 社区弹幕）直连加载器
-- 规范源 URL 形如 https://api.animeko.org/episode/<episodeId>（apis/animeko_search.lua 产出）；
--   请求 <node>/v1/danmaku/<episodeId>，节点失败依次降级（api.animeko.org →
--   danmaku-global.myani.org → danmaku-cn.myani.org → s1.animeko.openani.org）

local msg = require('mp.msg')
local utils = require("mp.utils")
local aparse = require("modules/animeko_parse")

local NODES = {
    "https://api.animeko.org",
    "https://danmaku-global.myani.org",
    "https://danmaku-cn.myani.org",
    "https://s1.animeko.openani.org",
}

local USER_AGENT = 'uosc-danmaku/1.0 (mpv danmaku plugin)'

local function build_curl_args(url)
    local args = {
        'curl', '-L', '-s', '--compressed',
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
    table.insert(args, url)
    return args
end

-- 从规范 URL 提取 episodeId
local function extract_episode_id(url)
    return tostring(url):match("animeko%.org/episode/(%d+)")
end

-- 保存并加载最终弹幕 JSON（{c="time,color,mode,25,,,", m=text} 约定与其他 sites 加载器一致）
local function save_output_and_load(output_table, source_url)
    if #output_table == 0 then
        show_message('未获取到任何弹幕', 3)
        return false
    end
    save_danmaku_json(source_url, utils.format_json(output_table))
    load_danmaku(true)
    return true
end

-- 为 animeko 弹幕源加载弹幕（节点依次降级尝试）
function load_danmaku_for_animeko(path, callback)
    callback = callback or function() end
    local url = path or mp.get_property('stream-open-filename', '')
    local episode_id = extract_episode_id(url or '')
    if not episode_id then
        msg.error('无法从 URL 中解析 animeko episodeId: ' .. tostring(url))
        callback(false)
        return
    end

    local node_idx = 1
    local output_table = {}

    local function try_node()
        if node_idx > #NODES then
            msg.warn('animeko 全部节点尝试失败 episodeId=' .. episode_id)
            callback(false)
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
                local comments = aparse.parse_danmaku_list(utils.parse_json(out))
                if #comments == 0 then
                    -- 该集确实无弹幕（合法空结果）不再降级
                    show_message('好像没有弹幕哦', 3)
                    callback(false)
                    return
                end
                for _, c in ipairs(comments) do
                    output_table[#output_table + 1] = {
                        c = string.format('%s,%s,%s,25,,,', c.time, c.color, c.mode),
                        m = c.text,
                    }
                end
                callback(save_output_and_load(output_table, url))
            end)
    end

    try_node()
end
