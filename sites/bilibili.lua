local msg = require('mp.msg')
local utils = require("mp.utils")

local bmatch = require("modules/bilibili_match")

local user_agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

local function build_curl_args(url, extra_headers)
    local args = {
        'curl', '-L', '-s', '--compressed', '--user-agent', user_agent
    }
    extra_headers = extra_headers or {}
    for _, h in ipairs(extra_headers) do
        table.insert(args, '-H')
        table.insert(args, h)
    end
    if options.cookie_file and options.cookie_file ~= '' then
        table.insert(args, '-b')
        table.insert(args, mp.command_native({'expand-path', options.cookie_file}))
    end
    if options.proxy and options.proxy ~= '' then
        table.insert(args, '-x')
        table.insert(args, options.proxy)
    end
    table.insert(args, url)
    return args
end

local function get_cid()
    local cid, danmaku_id = nil, nil
    local tracks = mp.get_property_native("track-list")
    for _, track in ipairs(tracks) do
        if track["lang"] == "danmaku" then
            cid = track["external-filename"]:match("/(%d-)%.xml$")
            danmaku_id = track["id"]
            break
        end
    end
    return cid, danmaku_id
end

local function get_bilibili_id_and_page(path)
    local bvid, aid, page = nil, nil, nil
    if not bvid then
        bvid = path:match("/video/(BV[%w]+)")
            or path:match("[?&]bvid=(BV[%w]+)")
    end
    if not aid then
        aid = path:match("/video/av([%d]+)")
    end
    if not page then
        page = tonumber(path:match("[?&]p=(%d+)"))
    end
    return bvid, aid, page or 1
end

local function get_bilibili_pagelist_args(bvid, aid)
    local url
    if bvid ~= nil then
        url = "https://api.bilibili.com/x/player/pagelist?bvid=" .. bvid
    else
        url = "https://api.bilibili.com/x/player/pagelist?aid=" .. aid
    end
    local headers = {"Referer: https://www.bilibili.com/video/" .. (bvid or ("av" .. aid))}
    return build_curl_args(url, headers)
end

local function resolve_bilibili_cid(path, callback)
    -- 扩展支持：普通视频（BV/av）、番剧（ep）、课程（cheese）
    local api_bangumi_season = "https://api.bilibili.com/pgc/view/web/season"
    local api_cheese_season = "https://api.bilibili.com/pugv/view/web/season"

    local q = path
    -- 解析普通投稿视频
    local bvid, aid, p = get_bilibili_id_and_page(q)
    if bvid or aid then
        local args = get_bilibili_pagelist_args(bvid, aid)
        call_cmd_async(args, function(error, json)
            if error then
                msg.warn("Failed to request bilibili pagelist: " .. tostring(error))
                callback(nil)
                return
            end
            local data = utils.parse_json(json)
            local pages = data and data["data"]
            if type(pages) ~= "table" then
                callback(nil)
                return
            end
            local page_info = pages[p] or pages[1]
            local cid = page_info and page_info["cid"]
            local part = page_info and page_info["part"]
            callback(cid and tostring(cid) or nil, part and tostring(part) or nil)
        end)
        return
    end

    -- 番剧、番外等（含 ep）
    if q:find("bangumi/") and q:find("ep") then
        local epid = q:match("ep(%d+)") or q:match("ep(%d+)$")
        if not epid then
            callback(nil)
            return
        end
        local url = api_bangumi_season .. "?ep_id=" .. epid
        local arg = build_curl_args(url)
        call_cmd_async(arg, function(error, json)
            if error then
                msg.warn("Failed to request bilibili bangumi info: " .. tostring(error))
                callback(nil)
                return
            end
            local data = utils.parse_json(json)
            if not data or data.code ~= 0 or not data.result then
                msg.warn("bilibili bangumi api returned error")
                callback(nil)
                return
            end
            -- 查找正片
            local episodes = data.result.episodes or {}
            for _, ep in ipairs(episodes) do
                if tostring(ep.id) == tostring(epid) then
                    callback(tostring(ep.cid), tostring(ep.share_copy or ep.title or ""))
                    return
                end
            end
            -- 查找 section（花絮等）
            if type(data.result.section) == "table" then
                for _, sec in ipairs(data.result.section) do
                    if sec.episodes then
                        for _, ep in ipairs(sec.episodes) do
                            if tostring(ep.id) == tostring(epid) then
                                callback(tostring(ep.cid), tostring(ep.share_copy or ep.title or ""))
                                return
                            end
                        end
                    end
                end
            end
            callback(nil)
        end)
        return
    end

    -- cheese 课程
    if q:find("cheese/") and q:find("ep") then
        local epid = q:match("ep(%d+)") or q:match("ep(%d+)$")
        if not epid then
            callback(nil)
            return
        end
        local url = api_cheese_season .. "?ep_id=" .. epid
        local arg = build_curl_args(url)
        call_cmd_async(arg, function(error, json)
            if error then
                msg.warn("Failed to request bilibili cheese info: " .. tostring(error))
                callback(nil)
                return
            end
            local data = utils.parse_json(json)
            if not data or data.code ~= 0 or not data.data then
                msg.warn("bilibili cheese api returned error")
                callback(nil)
                return
            end
            local episodes = data.data.episodes or {}
            for _, ep in ipairs(episodes) do
                if tostring(ep.id) == tostring(epid) then
                    callback(tostring(ep.cid), tostring(ep.title or ""))
                    return
                end
            end
            callback(nil)
        end)
        return
    end

    -- 其它情况返回 nil
    callback(nil)
end

local function download_bilibili_danmaku(path, cid, from_menu, callback)
    local url = "https://comment.bilibili.com/" .. cid .. ".xml"
    local args = build_curl_args(url)

    call_cmd_async(args, function(error, out)
        if error then
            show_message("HTTP request failed, see console for details", 5)
            msg.error(error)
            callback(false)
            return
        end
        if not out or out == '' then
            callback(false)
            return
        end
        save_danmaku_xml(path, out)
        load_danmaku(from_menu == nil and true or from_menu)
        callback(true)
    end)
end

-- 为 bilibli 网站的视频播放加载弹幕
function load_danmaku_for_bilibili(path, callback)
    callback = callback or function() end
    local cid, danmaku_id = get_cid()
    if danmaku_id ~= nil then
        mp.commandv('sub-remove', danmaku_id)
    end

    if cid == nil then
        cid = mp.get_opt('cid')
        if not cid then
            local patterns = {
                "bilivideo%.c[nom]+.*/resource/(%d+)%D+.*",
                "bilivideo%.c[nom]+.*/(%d+)-%d+-%d+%..*%?",
            }
            local urls = {
                path,
                mp.get_property("stream-open-filename", ''),
            }

            for _, pattern in ipairs(patterns) do
                for _, url in ipairs(urls) do
                    if url:find(pattern) then
                        cid = url:match(pattern)
                        break
                    end
                end
            end
        end
    end
    if cid == nil then
        resolve_bilibili_cid(path, function(resolved_cid)
            if resolved_cid then
                download_bilibili_danmaku(path, resolved_cid, true, callback)
            else
                show_message("获取哔哩哔哩视频cid失败", 3)
                msg.error("获取哔哩哔哩视频cid失败")
                callback(false)
            end
        end)
        return
    end
    if cid ~= nil then
        download_bilibili_danmaku(path, cid, true, callback)
    end
end

--------------------------------------------------------------------------------
-- B站合集弹幕记忆（文件夹级）
-- 在文件夹内任一集手动添加过B站视频弹幕源后，同文件夹其他剧集播放时
-- 自动按分P标题/集数差/时长匹配对应分P并加载弹幕
-- 记录存于 danmaku-history.json 的 history[dir].bilibili（多视频映射，上限 LRU 淘汰）
--------------------------------------------------------------------------------

local BILIBILI_PAGELIST_CACHE = {}  -- vid -> pages 数组（会话级缓存）
local BILIBILI_MAX_VIDS = 3         -- 每文件夹最多记忆的视频数

-- 规范化 URL：永远显式 ?p=N，作为弹幕源 key（保证重放/记忆键一致）
local function canonical_bilibili_url(vid, page)
    return string.format("https://www.bilibili.com/video/%s/?p=%d", vid, page)
end

-- 解析 URL -> vid（"BVxxxx" / "av123"）, 显式p|nil
-- 番剧 ep / 课程 cheese / b23.tv 短链均返回 nil（不支持文件夹记忆）
local function parse_bilibili_vid(url)
    if type(url) ~= "string" then return nil, nil end
    local bvid, aid, p = get_bilibili_id_and_page(url)
    local vid = bvid or (aid and ("av" .. aid) or nil)
    if vid == nil then return nil, nil end
    return vid, url:find("[?&]p=%d+") ~= nil and p or nil
end

-- 拉取分P列表（带会话级缓存）；callback(pages 数组或 nil)
local function fetch_bilibili_pagelist(vid, callback)
    local cached = BILIBILI_PAGELIST_CACHE[vid]
    if cached ~= nil then
        callback(cached)
        return
    end
    local bvid = vid:match("^BV[%w]+$")
    local aid = (not bvid) and vid:match("^av(%d+)$") or nil
    if not bvid and not aid then
        callback(nil)
        return
    end
    local args = get_bilibili_pagelist_args(bvid, aid)
    call_cmd_async(args, function(error, json)
        if error then
            msg.warn("Failed to request bilibili pagelist: " .. tostring(error))
            callback(nil)
            return
        end
        local data = utils.parse_json(json)
        local pages = data and data["data"]
        if type(pages) ~= "table" or #pages == 0 then
            callback(nil)
            return
        end
        BILIBILI_PAGELIST_CACHE[vid] = pages
        callback(pages)
    end)
end

-- 按 vid+page 直连下载弹幕（走缓存取 cid，源 key 为规范化 URL）
local function load_bilibili_danmaku_by_page(vid, page, callback)
    fetch_bilibili_pagelist(vid, function(pages)
        local info = pages and pages[page]
        if info == nil or info["cid"] == nil then
            callback(false)
            return
        end
        download_bilibili_danmaku(canonical_bilibili_url(vid, page), tostring(info["cid"]), true, callback)
    end)
end

-- 已存在同 (vid, page) 的弹幕源？（按解析结果对比，兼容旧记录省略 ?p=1 的情况）
local function bilibili_source_exists(url)
    local vid, page = parse_bilibili_vid(url)
    if vid == nil then return false end
    page = page or 1
    for k in pairs(DANMAKU.sources) do
        if type(k) == "string" and k:find("bilibili%.com/video/") then
            local kv, kp = parse_bilibili_vid(k)
            if kv == vid and (kp or 1) == page then
                return true
            end
        end
    end
    return false
end

local function read_history_table()
    local history_json = read_file(HISTORY_PATH)
    if history_json == nil then return {} end
    return utils.parse_json(history_json) or {}
end

-- 合并 patch 到 history[dir].bilibili[vid]；超过上限按 ts 淘汰最旧
function update_bilibili_series_record(dir, vid, patch)
    if dir == nil or vid == nil then return end
    local history = read_history_table()
    local record = history[dir] or {}
    local bl = record.bilibili or {}
    local entry = bl[vid] or {}
    for k, v in pairs(patch) do
        entry[k] = v
    end
    bl[vid] = entry
    record.bilibili = bl
    history[dir] = record
    local vids = {}
    for v, e in pairs(bl) do
        vids[#vids + 1] = { vid = v, ts = e.ts or 0 }
    end
    if #vids > BILIBILI_MAX_VIDS then
        table.sort(vids, function(a, b) return a.ts > b.ts end)
        for i = BILIBILI_MAX_VIDS + 1, #vids do
            bl[vids[i].vid] = nil
        end
    end
    write_json_file(HISTORY_PATH, history)
end

-- 清除文件夹的全部B站记忆 -> 是否清除过
function clear_bilibili_series_record(dir)
    if dir == nil then return false end
    local history = read_history_table()
    local record = history[dir]
    if record == nil or record.bilibili == nil then return false end
    record.bilibili = nil
    write_json_file(HISTORY_PATH, history)
    return true
end

-- 将 patch 同步进当前文件夹该 URL 对应视频的记忆（记录不存在时 no-op）
function sync_bilibili_series_source(url, patch)
    local vid = parse_bilibili_vid(url)
    if vid == nil then return end
    local path = mp.get_property("path")
    if path == nil or is_protocol(path) then return end
    local dir = get_parent_directory(path)
    local history = read_history_table()
    local record = history[dir]
    if record == nil or record.bilibili == nil or record.bilibili[vid] == nil then
        return
    end
    update_bilibili_series_record(dir, vid, patch)
end

-- 删除当前文件夹该 URL 对应视频的记忆（源管理菜单 delete 时防复活）-> 是否删除过
function remove_bilibili_series_record_for_url(url)
    local vid = parse_bilibili_vid(url)
    if vid == nil then return false end
    local path = mp.get_property("path")
    if path == nil or is_protocol(path) then return false end
    local dir = get_parent_directory(path)
    local history = read_history_table()
    local record = history[dir]
    if record == nil or record.bilibili == nil or record.bilibili[vid] == nil then
        return false
    end
    record.bilibili[vid] = nil
    if next(record.bilibili) == nil then
        record.bilibili = nil
    end
    write_json_file(HISTORY_PATH, history)
    return true
end

-- 手动添加B站源时记录文件夹记忆（在 add_danmaku_source 粘贴路径调用，与取数路径无关）
function maybe_record_bilibili_series(query)
    if options.bilibili_series_memory == "off" then return end
    local path = mp.get_property("path")
    if path == nil or is_protocol(path) then return end
    local dir = get_parent_directory(path)
    local vid, explicit_p = parse_bilibili_vid(query)
    if dir == nil or vid == nil then return end
    local _, season, episode = parse_title()
    fetch_bilibili_pagelist(vid, function(pages)
        if mp.get_property("path") ~= path then return end
        if pages == nil then
            msg.warn("B站分P列表获取失败，未写入文件夹记忆：" .. vid)
            return
        end
        -- 显式 ?p= 直接信任；无 ?p= 时对当前集做一次匹配。
        -- 匹配失败按B站惯例记 p1 ↔ 第1集（裸链接语义即该投稿的第1个分P，
        -- 不能锚到粘贴时的当前集——在第9集贴裸链会把锚点带偏）
        local page = explicit_p
        local anchor_ep = episode and tonumber(episode) or nil
        if page == nil then
            local m = bmatch.match_bilibili_part({
                parts = pages,
                season = season and tonumber(season) or nil,
                episode = episode and tonumber(episode) or nil,
                duration = mp.get_property_number("duration"),
            })
            if m then
                page = m.page
            else
                page, anchor_ep = 1, 1
            end
        end
        update_bilibili_series_record(dir, vid, {
            page = page,
            episode = anchor_ep,
            season = season and tonumber(season) or nil,
            ts = os.time(),
        })
        show_message("已记忆B站弹幕源，本文件夹将自动匹配分P", 3)
    end)
end

-- 文件夹记忆自动加载：对每个记忆视频匹配当前集的分P并加载
-- mode: add-与弹弹play流程叠加 / first-匹配成功则跳过弹弹play（全败回退）
function autoload_bilibili_series(path, dir, records, fallback)
    local mode = options.bilibili_series_memory == "first" and "first" or "add"
    local _, season, episode = parse_title()
    local season_n = season and tonumber(season) or nil
    local episode_n = episode and tonumber(episode) or nil
    local duration = mp.get_property_number("duration")

    -- 记忆按 ts 降序（最近使用的优先），保证确定性
    local vids = {}
    for vid, rec in pairs(records) do
        vids[#vids + 1] = { vid = vid, ts = rec.ts or 0, rec = rec }
    end
    table.sort(vids, function(a, b) return a.ts > b.ts end)
    if #vids == 0 then
        if mode == "first" then fallback() end
        return
    end

    local remaining = #vids
    local matched_any = false
    local function finish()
        -- 过期回调（已切集）不得对当前文件触发旧文件的回退流程
        if mp.get_property("path") ~= path then return end
        if mode == "first" then
            if not matched_any then
                show_message("B站分P未匹配，回退自动加载", 3)
                fallback()
            end
        elseif not matched_any then
            show_message("B站分P未匹配，已跳过", 3)
        end
    end

    -- add 模式：弹弹play流程照常先跑（同步），B站层异步叠加
    if mode == "add" then fallback() end

    for _, item in ipairs(vids) do
        local vid, rec = item.vid, item.rec
        fetch_bilibili_pagelist(vid, function(pages)
            local function done(ok)
                if ok then matched_any = true end
                remaining = remaining - 1
                if remaining == 0 then finish() end
            end
            if mp.get_property("path") ~= path then
                done(false)
                return
            end
            if pages == nil then
                done(false)
                return
            end
            local m = bmatch.match_bilibili_part({
                parts = pages,
                season = season_n,
                episode = episode_n,
                duration = duration,
                anchor_page = rec.page,
                anchor_episode = rec.episode,
                anchor_season = rec.season,
            })
            if m == nil then
                done(false)
                return
            end
            -- 匹配成功即更新锚点（下载失败多为瞬时网络问题，锚点本身是对的）
            update_bilibili_series_record(dir, vid, {
                page = m.page,
                episode = episode_n,
                season = season_n,
                ts = os.time(),
            })
            show_message(string.format("B站弹幕自动匹配：P%d %s", m.page, m.part or ""), 3)
            if DANMAKU.anime == nil then
                local t = parse_title()
                DANMAKU.anime = t
            end
            if DANMAKU.episode == nil then
                DANMAKU.episode = m.part
            end
            local url = canonical_bilibili_url(vid, m.page)
            if bilibili_source_exists(url) then
                done(true)  -- 已有同 (vid,page) 源（重放/手动添加过），交给 addon_danmaku
                return
            end
            -- 预置持久化标志；save_danmaku_xml 只补 data 不覆盖既有字段
            DANMAKU.sources[url] = DANMAKU.sources[url] or {
                from = "user_custom",
                blocked = rec.blocked or false,
                delay_segments = rec.delay_segments and shallow_copy(rec.delay_segments) or nil,
            }
            load_bilibili_danmaku_by_page(vid, m.page, function(ok)
                done(ok)
            end)
        end)
    end
end
