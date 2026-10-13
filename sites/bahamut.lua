-- 巴哈姆特动画疯域名直连弹幕加载器（在线播放 bahamut.akamaized.net 流自动加载、
--   extcomment 无数据时的回退路径共用）
-- 弹幕磁盘缓存（键 baha:{sn}）：TTL 内命中零网络；主端口（danmuGet.php）与降级端口
-- （danmu.php）均网络失败回退过期缓存（断网可看）；成功且非空写缓存——载荷统一为
-- comments 数组（两端口条目字段同构 color/position/time/text，读回经同一解析路径）

local msg = require('mp.msg')
local utils = require("mp.utils")
local dcache = require("modules/danmaku_cache")

local function resolve_bahamut_sn(input_string)
    -- 优先识别规范播放页 URL 的 sn 查询参数（apis/bahamut_search.lua 产出此形式）
    local qsn = input_string:match("[?&]sn=(%d+)")
    if qsn then
        return qsn
    end
    -- 兼容旧形式：sn 位于第 2、3 个冒号之间
    local start_index = 0
    local end_index = 0
    local count = 0
    for i = 1, #input_string do
        if input_string:sub(i, i) == ":" then
            count = count + 1
            if count == 2 then
                start_index = i
            elseif count == 3 then
                end_index = i
                break
            end
        end
    end
    if start_index > 0 and end_index > 0 then
        return input_string:sub(start_index + 1, end_index - 1)
    else
        return nil
    end
end

local function get_type_from_position(position)
    if position == 0 then
        return 1
    end
    if position == 1 then
        return 4
    end
    return 5
end

-- 弹幕磁盘缓存键（sn 唯一标识一集）
local function cache_key(sn)
    return "baha:" .. sn
end

-- 缓存载荷（comments 数组 JSON）→ 条目表；非数组/空数组视为无效（损坏条目）
local function parse_payload(payload)
    if type(payload) ~= "string" then return nil end
    local comments = utils.parse_json(payload)
    if type(comments) ~= "table" or #comments == 0 then return nil end
    return comments
end

-- 为 bahamut 网站的视频播放加载弹幕
function load_danmaku_for_bahamut(path, callback)
    callback = callback or function() end
    local path = path:gsub('%%(%x%x)', hex_to_char)
    local sn = resolve_bahamut_sn(path)
    if sn == nil then
        callback(false)
        return
    end
    local key = cache_key(sn)

    -- 保存弹幕条目（danmuGet.php 与 danmu.php 的条目字段同构：color/position/time/text）
    local function save_comments(comments)
        local output_table = {}
        for _, comment in ipairs(comments) do
            local color = hex_to_int_color(comment["color"])
            local mode = get_type_from_position(comment["position"])
            local time = tonumber(comment["time"]) / 10
            local c_param = string.format("%s,%s,%s,25,,,", time, color, mode)
            table.insert(output_table, {
                c = c_param,
                m = comment["text"]
            })
        end

        local final_json_str = utils.format_json(output_table)
        save_danmaku_json("https://ani.gamer.com.tw/animeVideo.php?sn=" .. sn, final_json_str)
        load_danmaku(true, nil, true)
        callback(true)
    end

    -- 两端口均网络失败 → 过期缓存兜底（断网可看）
    local function try_stale_cache()
        local stale = dcache.get_stale(key)
        local comments = stale and parse_payload(stale.payload) or nil
        if comments then
            DANMAKU.cache_hit = "stale"
            show_message("网络失败，已使用过期弹幕缓存", 3)
            save_comments(comments)
        else
            show_message("好像没有弹幕哦", 3)
            callback(false)
        end
    end

    -- 降级端点：App API danmu.php（GET，大陆直连可达性更好；弹幕在 data.danmu 数组）
    local function try_danmu_api()
        local api_url = "https://api.gamer.com.tw/anime/v1/danmu.php?geo=TW%2CHK&videoSn=" .. sn
        local api_arg = {
            "curl",
            "-L",
            "-s",
            "--compressed",
            "--user-agent",
            "Anime/2.29.2 (7N5749MM3F.tw.com.gamer.anime; build:972; iOS 26.0.0) Alamofire/5.6.4",
        }
        if options.proxy ~= "" then
            table.insert(api_arg, '-x')
            table.insert(api_arg, options.proxy)
        end
        if options.cookie_file and options.cookie_file ~= "" then
            table.insert(api_arg, '-b')
            table.insert(api_arg, mp.command_native({"expand-path", options.cookie_file}))
        end
        append_curl_timeout(api_arg)
        table.insert(api_arg, api_url)

        call_cmd_async(api_arg, function(api_err, api_out)
            if api_err then
                -- 主端口已败至此、降级端口亦网络失败 → 过期缓存兜底
                msg.warn("巴哈 danmu.php 请求失败: " .. tostring(api_err))
                try_stale_cache()
                return
            end
            local data = utils.parse_json(api_out or '')
            local comments = data and data["data"] and data["data"]["danmu"]
            if type(comments) ~= "table" or #comments == 0 then
                -- 该集确实无弹幕（合法空结果）不缓存
                show_message("好像没有弹幕哦", 3)
                callback(false)
                return
            end
            -- 成功且非空写缓存（载荷为 comments 数组，与命中读回同构）
            dcache.put(key, utils.format_json(comments), { type = "json", count = #comments })
            save_comments(comments)
        end)
    end

    -- 1) TTL 内命中缓存：不发网络（置于取数函数定义后——save_comments 为其闭包依赖）
    local hit = dcache.get(key)
    if hit then
        local comments = parse_payload(hit.payload)
        if comments then
            DANMAKU.cache_hit = "cache"
            msg.verbose("弹幕缓存命中：" .. key)
            save_comments(comments)
            return
        end
        dcache.remove(key)
    end

    local url = "https://ani.gamer.com.tw/ajax/danmuGet.php"
    local temp_file = "bahamut-" .. PID .. ".json"
    local danmaku_json = utils.join_path(DANMAKU_PATH, temp_file)
    local arg = {
        "curl",
        "-X",
        "POST",
        "-d",
        "sn=" .. sn,
        "-L",
        "-s",
        "--user-agent",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/85.0.4183.83 Safari/537.36",
        "--header",
        "Origin: https://ani.gamer.com.tw",
        "--header",
        "Content-Type: application/x-www-form-urlencoded;charset=utf-8",
        "--header",
        "Accept: application/json",
        "--header",
        "Authority: ani.gamer.com.tw",
        "--output",
        danmaku_json,
        url,
    }

    if options.proxy ~= "" then
        table.insert(arg, '-x')
        table.insert(arg, options.proxy)
    end

    if options.cookie_file and options.cookie_file ~= "" then
        table.insert(arg, '-b')
        table.insert(arg, mp.command_native({"expand-path", options.cookie_file}))
    end
    append_curl_timeout(arg)

    call_cmd_async(arg, function(error)
        if error then
            msg.warn("巴哈 danmuGet.php 请求失败，降级 danmu.php: " .. tostring(error))
            try_danmu_api()
            return
        end
        if not file_exists(danmaku_json) then
            try_danmu_api()
            return
        end

        local comments_json = read_file(danmaku_json)
        os.remove(danmaku_json)
        local comments = utils.parse_json(comments_json)
        if not comments or #comments == 0 then
            try_danmu_api()
            return
        end

        -- 2) 成功且非空写缓存（载荷为 comments 数组）后走原路径
        dcache.put(key, utils.format_json(comments), { type = "json", count = #comments })
        save_comments(comments)
    end)
end
