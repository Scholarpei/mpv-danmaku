-- 埋堆堆（TVB 港剧）关键词搜索流程（搜索后缀 |mdd）
-- 接口（全部 POST mob.mddcloud.com.cn，md5 固定私钥签名，见 modules/maiduidui_parse.lua）：
--   /searchApi/search/getAllSearchResult.action 搜索（分组结果，粤语/国语版本分列）→
--   /api/vod/listVodSactions.action 分集列表（vodUuid → 每集 uuid）→
--   选集后拼 https://www.mddcloud.com.cn/video/<vodUuid>.html?uuid=<epUuid> 规范 URL
--   交给 add_danmaku_source 现有管线（extcomment 短路 → 域名直连 sites/maiduidui.lua）
-- 历史续载：DANMAKU.extra 记 kind="maiduidui"，main.lua 的 dandanplay_flow 按 kind 分发

local msg = require("mp.msg")
local utils = require("mp.utils")
local mparse = require("modules/maiduidui_parse")

local BASE = "https://mob.mddcloud.com.cn"
local SEARCH_PATH = "/searchApi/search/getAllSearchResult.action"
local SACTIONS_PATH = "/api/vod/listVodSactions.action"

local function build_mdd_args(path, data)
    local time_ms = os.time() * 1000 + math.random(0, 999)
    local sign = mparse.sign(path, data, time_ms)
    local body = mparse.wrap_body(data, time_ms, sign)

    local args = {
        'curl',
        '-L',
        '-s',
        '--compressed',
        '--user-agent', 'Mdd/5.8.00 (Android+32+)',
        '-H', 'Content-Type: application/json',
        '-H', 'version: 5.8.00',
        '-H', 'Referer: https://www.mddcloud.com.cn',
        '-X', 'POST',
        '-d', utils.format_json(body),
    }
    if options.cookie_file and options.cookie_file ~= '' then
        args[#args + 1] = '-b'
        args[#args + 1] = mp.command_native({'expand-path', options.cookie_file})
    end
    if options.proxy ~= '' then
        args[#args + 1] = '-x'
        args[#args + 1] = options.proxy
    end
    args[#args + 1] = BASE .. path
    return args
end

-- 拉取分集列表；callback(episodes)，失败传 nil
local function fetch_mdd_episodes(vod_uuid, callback)
    call_cmd_async_with_timeout(build_mdd_args(SACTIONS_PATH, {
        hasIntroduction = 0,
        vodUuid = vod_uuid,
    }), 15, function(err, out)
        if err then
            msg.warn("埋堆堆分集请求失败: " .. tostring(err))
            callback(nil)
            return
        end
        local parsed = mparse.parse_sactions(utils.parse_json(out))
        if not parsed.ok or #parsed.episodes == 0 then
            msg.warn("埋堆堆分集为空 vod_uuid=" .. tostring(vod_uuid))
            callback(nil)
            return
        end
        callback(parsed.episodes)
    end)
end

-- 选集后加载（菜单选集与历史续载共用）
local function load_maiduidui_danmaku(vod_uuid, ep_uuid, episodenum, title, material_name)
    ENABLED = true
    DANMAKU.anime = title
    DANMAKU.episode = "第" .. episodenum .. "集"
    DANMAKU.source = "maiduidui"
    DANMAKU.extra = {
        kind = "maiduidui",
        vod_uuid = tostring(vod_uuid),
        title = title,
        material_name = material_name,
        episodenum = tonumber(episodenum),
    }
    write_history()
    add_danmaku_source(("https://www.mddcloud.com.cn/video/%s.html?uuid=%s"):format(vod_uuid, ep_uuid),
        true, "埋堆堆")
end

-- 历史续载入口：按 kind="maiduidui" 记录推算目标集数后由 main.lua 调入
function resume_maiduidui_episode(extra, episodenum)
    fetch_mdd_episodes(extra.vod_uuid, function(episodes)
        if not episodes then
            show_message("埋堆堆弹幕续载失败：无法获取剧集列表", 3)
            msg.warn("埋堆堆续载：剧集列表为空 vod_uuid=" .. tostring(extra.vod_uuid))
            return
        end
        local ep = episodes[episodenum]
        if not ep then
            show_message(("埋堆堆弹幕续载失败：第 %d 集不存在（共 %d 集）")
                :format(episodenum, #episodes), 3)
            return
        end
        load_maiduidui_danmaku(extra.vod_uuid, ep.uuid, episodenum, extra.title, extra.material_name)
    end)
end

-- 搜索解析结果 → menu_anime 条目（|mdd 单源流与聚合搜索共用）
-- 埋堆堆无年份字段，hint 显示类型与集数
function build_maiduidui_search_items(parsed_items)
    local items = {}
    for _, it in ipairs(parsed_items) do
        items[#items + 1] = {
            title = it.name,
            hint = it.material_name .. " | " .. it.total .. "集",
            value = { "script-message-to", mp.get_script_name(), "get-mdd-event",
                it.vod_uuid, it.name, it.material_name },
        }
    end
    return items
end

-- 仅取数：搜索异步请求；callback(items, err)，返回取消函数
function fetch_maiduidui_search(query, callback, timeout)
    return call_cmd_async_with_timeout(build_mdd_args(SEARCH_PATH, {
        keyWord = query,
    }), timeout, function(err, out)
        if err then
            callback(nil, "请求失败")
            return
        end
        local parsed = mparse.parse_search(utils.parse_json(out))
        if not parsed.ok then
            callback(nil, "接口错误")
            return
        end
        callback(build_maiduidui_search_items(parsed.items), nil)
    end)
end

-- |mdd 搜索入口（menu.lua 按 |mdd 后缀调入）
function query_maiduidui_search(name)
    local menu = {
        type = "menu_anime",
        title = "在此处输入番剧名称",
        footnote = "使用enter或ctrl+enter进行搜索",
    }
    menu.cmd = { "script-message-to", mp.get_script_name(), "search-anime-event" }

    local function show(text)
        if uosc_available then
            update_menu_uosc(menu.type, menu.title, text, menu.footnote, menu.cmd, name)
        else
            show_message(text, 3)
        end
    end

    local function search(query)
        if uosc_available then
            update_menu_uosc(menu.type, menu.title, "加载数据中...", menu.footnote, menu.cmd, query, "spinner")
        else
            show_message("加载数据中...", 30)
        end
        fetch_maiduidui_search(query, function(items, err)
            if err then
                msg.error("埋堆堆搜索失败：" .. tostring(err))
                show("无结果")
                return
            end
            if #items == 0 then
                show("无结果")
                return
            end
            if uosc_available then
                latest_menu_anime = update_menu_uosc(menu.type, menu.title, items, menu.footnote, menu.cmd, query)
            else
                show_message("", 0)
                mp.add_timeout(0.1, function()
                    open_menu_select(items)
                end)
            end
        end)
    end

    -- 非中文关键词先经 TMDB 换中文译名；失败不阻断
    if not is_chinese(name) and type(query_tmdb) == "function"
        and options.tmdb_api_key ~= "" and #Base64.decode(options.tmdb_api_key) >= 32 then
        local title = query_tmdb(name, "tv", menu)
        if title then
            name = title
        end
    end
    search(name)
end

mp.register_script_message("get-mdd-event", function(vod_uuid, title, material_name)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_anime")
    end

    local menu_type = "menu_details"
    local menu_title = title
    local footnote = "使用 / 打开筛选"
    if uosc_available then
        update_menu_uosc(menu_type, menu_title, "加载数据中...", footnote)
    else
        show_message("查询弹幕中...", 3)
    end

    fetch_mdd_episodes(vod_uuid, function(episodes)
        if not episodes then
            local message = "无结果"
            if uosc_available then
                update_menu_uosc(menu_type, menu_title, message, footnote)
            else
                show_message(message, 3)
            end
            return
        end

        local items = {
            {
                title = "↩️ 返回搜索结果",
                value = { "script-message-to", "uosc", "open-menu", latest_menu_anime },
                keep_open = false,
                selectable = true,
            },
        }
        for i, ep in ipairs(episodes) do
            items[#items + 1] = {
                title = ep.name ~= "" and ep.name or ("第" .. i .. "集"),
                value = { "script-message-to", mp.get_script_name(), "add-mdd-event",
                    vod_uuid, ep.uuid, tostring(i), title, material_name },
            }
        end
        if uosc_available then
            update_menu_uosc(menu_type, menu_title, items, footnote)
        else
            show_message("", 0)
            mp.add_timeout(0.1, function()
                open_menu_select(items)
            end)
        end
    end)
end)

mp.register_script_message("add-mdd-event", function(vod_uuid, ep_uuid, episodenum, title, material_name)
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "menu_details")
    end
    load_maiduidui_danmaku(vod_uuid, ep_uuid, episodenum, title, material_name)
end)
