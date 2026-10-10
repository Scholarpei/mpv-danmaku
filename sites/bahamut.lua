local msg = require('mp.msg')
local utils = require("mp.utils")

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

-- 为 bahamut 网站的视频播放加载弹幕
function load_danmaku_for_bahamut(path, callback)
    callback = callback or function() end
    local path = path:gsub('%%(%x%x)', hex_to_char)
    local sn = resolve_bahamut_sn(path)
    if sn == nil then
        callback(false)
        return
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
        load_danmaku(true)
        callback(true)
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
        table.insert(api_arg, api_url)

        call_cmd_async(api_arg, function(api_err, api_out)
            local data = not api_err and utils.parse_json(api_out or '') or nil
            local comments = data and data["data"] and data["data"]["danmu"]
            if type(comments) ~= "table" or #comments == 0 then
                show_message("好像没有弹幕哦", 3)
                callback(false)
                return
            end
            save_comments(comments)
        end)
    end

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

        save_comments(comments)
    end)
end
