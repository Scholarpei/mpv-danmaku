-- 埋堆堆（TVB）直连弹幕加载器
-- 规范源 URL 形如 https://www.mddcloud.com.cn/video/<vodUuid>.html?uuid=<epUuid>
--   （apis/maiduidui_search.lua 产出）；单次 vodBarrage396(times=0) 返回全集弹幕

local msg = require('mp.msg')
local utils = require("mp.utils")
local mparse = require("modules/maiduidui_parse")

local BASE = "https://mob.mddcloud.com.cn"
local BARRAGE_PATH = "/api/barrage/vodBarrage396.action"

local function build_curl_args(body_json)
    local args = {
        'curl', '-L', '-s', '--compressed',
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

-- 为埋堆堆弹幕源加载弹幕
function load_danmaku_for_maiduidui(path, callback)
    callback = callback or function() end
    local url = path or mp.get_property('stream-open-filename', '')
    local vod_uuid, ep_uuid = extract_uuids(url)
    if not vod_uuid or not ep_uuid then
        msg.error('无法从 URL 解析埋堆堆 vodUuid/分集uuid: ' .. tostring(url))
        callback(false)
        return
    end

    local time_ms = os.time() * 1000 + math.random(0, 999)
    local data = { sactionUuid = ep_uuid, times = 0, vodUuid = vod_uuid }
    local sign = mparse.sign(BARRAGE_PATH, data, time_ms)
    local body = mparse.wrap_body(data, time_ms, sign)

    call_cmd_async_with_timeout(build_curl_args(utils.format_json(body)), 15,
        function(err, out)
            if err or not out or out == '' then
                msg.warn('埋堆堆弹幕请求失败: ' .. tostring(err))
                callback(false)
                return
            end
            local comments = mparse.parse_barrage(utils.parse_json(out))
            if #comments == 0 then
                show_message('好像没有弹幕哦', 3)
                callback(false)
                return
            end
            local output_table = {}
            for _, c in ipairs(comments) do
                output_table[#output_table + 1] = {
                    c = string.format('%s,%s,%s,25,,,', c.time, c.color, c.mode),
                    m = c.text,
                }
            end
            save_danmaku_json(url, utils.format_json(output_table))
            load_danmaku(true)
            callback(true)
        end)
end
