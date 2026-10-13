-- AcFun（A站）搜索/视频页/合集页/弹幕的纯解析函数（无硬性 mp.* 硬依赖以外仅 mp.utils，便于单元测试）
-- 调用方：apis/acfun_search.lua、sites/acfun.lua
--
-- 接口形态（2026-10 实测，见 tests/fixtures/acf_*）：
--   搜索 GET https://www.acfun.cn/search?keyword=<kw> —— 服务端 BigPipe 渲染，
--     结果在 <script>bigpipe.onPageletArrive({"id":"pagelet_xxx","html":"..."})</script> 内嵌块里
--     （html 为 JSON 转义字符串，含完整条目 HTML）。本插件取 pagelet_video（单视频）与
--     pagelet_album（多P合集）；pagelet_bangumi 番剧区实测多关键词恒空（正版库已枯竭）不解析。
--     视频条目：class="search-video" 块，/v/ac{ac号}、video__main__title 锚文本、
--       video__duration 时长、info__danmaku-count 弹幕数、user-name UP主
--     合集条目：class="search-album" 块，/a/aa{aa号}、album__main__title 锚文本
--   视频页 GET https://www.acfun.cn/v/ac{ac号} —— window.pageInfo = {…} 内嵌 JSON：
--     title/user.name/videoList[{id(videoId), title}]（多P 按序）/currentVideoInfo.id（单P 兜底）
--   合集页 GET https://www.acfun.cn/a/aa{aa号} —— window.__INITIAL_STATE__ = {…}：
--     album.albumContent.contentList[{resourceId(ac号), resourceType="DOUGA", title, sort}]
--     —— 按sort升序即正片顺序（65536/集，实测页面原始顺序为倒序不可直接用）
--   弹幕 POST https://www.acfun.cn/rest/pc-direct/new-danmaku/list（表单）：
--     resourceId={videoId}&resourceType=9&enableAdvanced=true&pcursor={游标}&count=200&sortType=1&asc=false
--     首页 pcursor=0，响应 pcursor 为下一页游标（实测 "2"），"no_more" 即止；
--     danmakus[] 条目 {body 文本, position 毫秒, color 整数RGB, mode 1滚动/4底/5顶（与B站同语义）, size}

local utils = require("mp.utils")

local M = {}

-- ============ 通用：内嵌 JSON 提取 ============

-- 从 text 的 start（指向 '{'）做字符串感知的花括号配平，返回配对 '}' 的位置；失败 nil
-- （不感知字符串内花括号会被含 {} 的标题击穿，故必须逐字符扫转义与引号状态）
local function scan_json(text, start)
    local depth, i, n = 0, start, #text
    local in_str = false
    while i <= n do
        local c = text:byte(i)
        if in_str then
            if c == 92 then -- 反斜杠：跳过被转义字符
                i = i + 1
            elseif c == 34 then
                in_str = false
            end
        else
            if c == 34 then
                in_str = true
            elseif c == 123 then -- {
                depth = depth + 1
            elseif c == 125 then -- }
                depth = depth - 1
                if depth == 0 then return i end
            end
        end
        i = i + 1
    end
    return nil
end

-- 在 html 中定位 marker 后的首个完整 JSON 对象并解析；失败返回 nil
-- marker 形如 "window.pageInfo" / "window.__INITIAL_STATE__"（取 '=' 之后首个 '{'）
function M.extract_page_json(html, marker)
    if type(html) ~= "string" then return nil end
    local m = html:find(marker, 1, true)
    if not m then return nil end
    local eq = html:find("=", m, true)
    if not eq then return nil end
    local bstart = html:find("{", eq, true)
    if not bstart then return nil end
    local bend = scan_json(html, bstart)
    if not bend then return nil end
    return utils.parse_json(html:sub(bstart, bend))
end

-- 常用 HTML 实体解码（搜索条目锚文本用；照 modules/tencent_parse.lua 内联风格自含）
local function decode_entities(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("&nbsp;", " "):gsub("&quot;", '"'):gsub("&#39;", "'")
        :gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end

-- ============ 搜索页 ============

-- 按 'class="search-video"' 等块前缀把 pagelet html 切成逐条目块（末块无后续前缀，
-- 取到串尾），对每块调 mapper(block)。plain find 无模式元字符问题。
local function for_each_item(h, block_prefix, mapper)
    local start = 1
    while true do
        local s = h:find(block_prefix, start, true)
        if not s then return end
        local e = h:find(block_prefix, s + #block_prefix, true)
        mapper(h:sub(s, e and (e - 1) or #h))
        if not e then return end
        start = e
    end
end

local function make_video_item(block)
    local ac = block:match('href="/v/ac(%d+)"')
    if not ac then return end
    return {
        type = "video",
        ac_id = ac,
        title = decode_entities(block:match('video__main__title%s*[^>]*>%s*<a[^>]*>(.-)</a>') or ""),
        duration = decode_entities(block:match('video__duration">(.-)</span>') or ""),
        danmu = decode_entities(block:match('info__danmaku%-count">(.-)</span>') or ""),
        user = decode_entities(block:match('user%-name">(.-)</span>') or ""),
    }
end

local function make_album_item(block)
    local aa = block:match('href="/a/aa(%d+)"')
    if not aa then return end
    return {
        type = "album",
        aa_id = aa,
        title = decode_entities(block:match('album__main__title%s*[^>]*>%s*<a[^>]*>(.-)</a>') or ""),
        user = decode_entities(block:match('user%-name">(.-)</span>') or ""),
    }
end

local function append_video_items(h, items)
    for_each_item(h, 'class="search-video"', function(block)
        local it = make_video_item(block)
        if it then items[#items + 1] = it end
    end)
end

local function append_album_items(h, items)
    for_each_item(h, 'class="search-album"', function(block)
        local it = make_album_item(block)
        if it then items[#items + 1] = it end
    end)
end

-- 搜索页 HTML → { ok=bool, items={ {type="video",ac_id,title,duration,danmu,user} |
--                                          {type="album",aa_id,title,user} } }
-- ok 仅表示完成了解析流程（含无结果的空表）；请求失败由调用方在 HTTP 层判定
function M.parse_search(html)
    local result = { ok = false, items = {} }
    if type(html) ~= "string" then return result end

    local pos, guard = 1, 0
    while true do
        local s = html:find("onPageletArrive(", pos, true)
        if not s then break end
        -- "onPageletArrive(" 长 16，参数对象 '{' 恰在 s+16（find 起点 s+16 含自身，s+17 会跳过真开头落进字符串内部）
        local bstart = html:find("{", s + 16, true)
        if not bstart then break end
        local bend = scan_json(html, bstart)
        if not bend then break end
        pos = bend + 1
        local obj = utils.parse_json(html:sub(bstart, bend))
        if type(obj) == "table" and type(obj.html) == "string" then
            if obj.id == "pagelet_video" then
                append_video_items(obj.html, result.items)
            elseif obj.id == "pagelet_album" then
                append_album_items(obj.html, result.items)
            end
        end
        guard = guard + 1
        if guard > 32 then break end -- 页面结构异常时的保险丝
    end
    result.ok = true
    return result
end

-- ============ 视频页（/v/ac{ac号}）============

-- → { ok=bool, title, user, videos={ {video_id, title} } }（多P 按页序；单P 走 currentVideoInfo 兜底）
function M.parse_video_page(html)
    local result = { ok = false, title = "", user = "", videos = {} }
    local obj = M.extract_page_json(html, "window.pageInfo")
    if type(obj) ~= "table" then return result end
    result.title = tostring(obj.title or "")
    result.user = type(obj.user) == "table" and tostring(obj.user.name or "") or ""
    if type(obj.videoList) == "table" and #obj.videoList > 0 then
        for _, v in ipairs(obj.videoList) do
            if type(v) == "table" and v.id then
                result.videos[#result.videos + 1] =
                    { video_id = tostring(v.id), title = tostring(v.title or "") }
            end
        end
    elseif type(obj.currentVideoInfo) == "table" and obj.currentVideoInfo.id then
        result.videos[1] = { video_id = tostring(obj.currentVideoInfo.id), title = result.title }
    end
    result.ok = #result.videos > 0
    return result
end

-- ============ 合集页（/a/aa{aa号}）============

-- → { ok=bool, title, parts={ {ac_id, title} } }（按 sort 升序=正片顺序；仅收 DOUGA 类型分P）
function M.parse_album_page(html)
    local result = { ok = false, title = "", parts = {} }
    local obj = M.extract_page_json(html, "window.__INITIAL_STATE__")
    if type(obj) ~= "table" or type(obj.album) ~= "table" then return result end

    local info = type(obj.album.albumInfo) == "table" and obj.album.albumInfo or {}
    result.title = tostring(info.title or info.intro or "")
    local content = type(obj.album.albumContent) == "table" and obj.album.albumContent or {}
    local cl = type(content.contentList) == "table" and content.contentList or {}

    local list = {}
    for _, c in ipairs(cl) do
        if type(c) == "table" and c.resourceType == "DOUGA" and c.resourceId then
            list[#list + 1] = {
                ac_id = tostring(c.resourceId),
                title = tostring(c.title or ""),
                sort = tonumber(c.sort) or 0,
            }
        end
    end
    table.sort(list, function(a, b) return a.sort < b.sort end)
    for _, p in ipairs(list) do
        result.parts[#result.parts + 1] = { ac_id = p.ac_id, title = p.title }
    end
    result.ok = #result.parts > 0
    return result
end

-- ============ 弹幕（POST new-danmaku/list 单页响应）============

-- → { ok=bool, comments={ {time=秒, color=整数, mode=1/4/5, text} }, pcursor=下一页游标或nil, total }
-- result~=0 拒绝；pcursor 为 "no_more"/空/0 页响应无游标 → nil（调用方据此停止分页）
function M.parse_danmaku(d)
    local out = { ok = false, comments = {}, pcursor = nil, total = 0 }
    if type(d) ~= "table" or d.result ~= 0 then return out end
    out.ok = true
    out.total = tonumber(d.totalCount) or 0
    local pc = d.pcursor
    if type(pc) == "number" and pc > 0 then
        out.pcursor = tostring(pc)
    elseif type(pc) == "string" and pc ~= "" and pc ~= "no_more" then
        out.pcursor = pc
    end
    if type(d.danmakus) == "table" then
        for _, c in ipairs(d.danmakus) do
            if type(c) == "table" and type(c.body) == "string" and c.body ~= "" then
                out.comments[#out.comments + 1] = {
                    time = (tonumber(c.position) or 0) / 1000,
                    color = tonumber(c.color) or 16777215,
                    mode = tonumber(c.mode) or 1,
                    text = c.body,
                }
            end
        end
    end
    return out
end

-- 聚合多页后的缓存载荷（与网络响应同构，读回走同一 parse_danmaku 路径）
function M.build_cache_payload(comments)
    local danmakus = {}
    for _, c in ipairs(comments) do
        danmakus[#danmakus + 1] = {
            body = c.text,
            position = math.floor(c.time * 1000 + 0.5),
            color = c.color,
            mode = c.mode,
            size = 25,
        }
    end
    return utils.format_json({
        result = 0,
        totalCount = #danmakus,
        danmakus = danmakus,
        pcursor = "no_more",
    })
end

return M
