-- girigirilove（girigiri愛動漫）搜索/详情页/播放页/弹幕 JSON 的纯解析函数
-- （除 mp.utils 零 mp 依赖，单测直打；照 modules/acfun_parse.lua 同款口径）
-- 调用方：apis/ggl_search.lua、sites/ggl.lua
--
-- 接口形态（2026-10-13 实测，见 tests/fixtures/ggl_*）：
--   搜索 GET https://ani.girigirilove.com/index.php/ajax/suggest?mid=1&wd=<kw> —— JSON。
--     ⚠️ 站方 HTML 搜索页 /search/-------------/?wd= 配反爬（无 JS 的 bot 环境恒空结果，
--     MacCMS 采集 API /api.php/provide/vod 亦返回 "closed"），本端点是站内搜索框
--     自动补全用的公开接口（search_auto=2 时启用），curl 直达。响应：
--     {"code":1,"list":[{"id":GV号,"name","en","pic"}],"total"}；无结果 total=0 list=[]。
--   详情 GET https://ani.girigirilove.com/GV{GV号}/ —— 线路 tab 区
--     <div class="anthology-tab…"><a class="swiper-slide">…繁中<span class="badge">4</span></a>…
--     与集数区 <div class="anthology-list…"> 内逐线路 <div class="anthology-list-box"> 各含
--     <ul class="anthology-list-play…">；tab 与 box 按索引对应。集数链接
--     <a href="/playGV{GV}-{线路src}-{集ep}/">标签</a>（标签形如 先行01/02/1080P；
--     页头导航也是 swiper-slide，tab 解析须锚定 anthology-tab 到 anthology-list 之间的区域）。
--     ⚠️ 多线路（繁中/简中/杜比…）的弹幕同池：弹幕接口按资源名模糊匹配，实测两线路
--     逐字节相同载荷——选集菜单取首条非空线路即可（ezdmw 主线线路同口径）。
--   播放页 GET https://ani.girigirilove.com/playGV{GV}-{src}-{ep}/ —— MacCMS 标准
--     player_aaaa={…,"encrypt":2,…,"url":"<base64>","from":"cht/chs/DB",…} 内嵌 JSON
--     （字符串感知花括号配平提取，照 acfun_parse 范本——标题含 {} 不会击穿）。
--     encrypt 0=明文 / 1=base64 / 2=base64(percent 编码)（实测全站 2：每字符 %XX 全编码），
--     解出裸 m3u8（形如 https://akua.girigirilove.com/zijian/oldanime/{年}/{月}/cht/
--     {罗马字}CHT/{集}/playlist.m3u8；剧场版单集无 {集} 段）。⚠️ 站方播放链路经
--     pl.girigirilove.com atom.php 播放器外壳，本实现跳过外壳直接解 player_aaaa。
--   弹幕 POST https://m3u8.girigirilove.com/api.php/Scrolling/getScrolling
--     头 Content-Type: application/json，body {"play_url":"<裸m3u8>"} —— CORS 全开 curl
--     直达，无需 referer。响应 {"code":1,"info":[{"scroll_id":…,"scroll_json":{
--     "stime":0,"mode":1,"text":"","color":"","time":秒(float),"content":"文本",
--     "style":{"color":"#ffffff"},"duration":8}}]}。
--     ⚠️ 文本在 content（text 恒空）、色在 style.color（hex，有 8 位 #ffffffff 变体
--     ——剥 alpha 取前 6 位）；mode 1滚动/2顶部/3底部（APlayer.min.js modeName 实锤，
--     →B站 1/5/4），duration 滚动 8 / 顶底 4；time 非有序。
--     合法空 = code=1 且 info=[]（该集确无弹幕）；code≠1/非 JSON = 接口错误。
-- 域名轮换史（维护备忘）：主域 ani.girigirilove.com；海外备用 anime.girigirilove.icu
--   （大陆 IP 403，仅 URL 识别用）；弹幕接口 m3u8.girigirilove.com；播放 CDN akua./pl.；
--   www.girigirilove.com 重定向到无关站 girilove.com（勿用）。

local utils = require("mp.utils")
local b64 = require("modules/base64")

local M = {}

-- ============ 内部小工具 ============

-- 字符串感知的花括号配平（照 modules/acfun_parse.lua 范本）：逐字符扫引号/转义
-- 状态再配平，含 {} 的字符串（标题等）不会击穿配平
local function scan_json(html, start)
    local depth, in_str, esc, i = 0, false, false, start
    while i <= #html do
        local c = html:byte(i)
        if in_str then
            if esc then
                esc = false
            elseif c == 92 then -- \
                esc = true
            elseif c == 34 then -- "
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
-- marker 形如 "player_aaaa"（取 '=' 之后首个 '{'）
local function extract_page_json(html, marker)
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

-- 常用 HTML 实体解码（&amp; 必须最后：&amp;lt; 应解成字面 "<" 而非二次解码）
local function decode_entities(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("&nbsp;", " "):gsub("&quot;", '"'):gsub("&#39;", "'")
        :gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end

-- percent 编码解码（encrypt=2 的 url 字段为逐字符 %XX 全编码，纯 ASCII 无多字节问题）
local function percent_decode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- hex 色 → 整数 RGB：接受 "#ffffff" 与 8 位 "#ffffffff"（剥 alpha 取前 6 位）；
-- 缺失/非法定义为白 0xFFFFFF
local function hex_color(s)
    if type(s) ~= "string" then return 0xFFFFFF end
    local h = s:match("^#(%x%x%x%x%x%x)")
    if not h then return 0xFFFFFF end
    return tonumber(h, 16)
end

-- ============ 搜索（ajax/suggest 响应 JSON）============

-- → { ok=bool, items={ {gv_id, title} } }
-- ok 仅表示完成了解析流程（含无结果的空表）；code≠1 / 非 JSON 为接口错误 ok=false
function M.parse_search(json_string)
    local result = { ok = false, items = {} }
    if type(json_string) ~= "string" then return result end
    local data = utils.parse_json(json_string)
    if type(data) ~= "table" or tonumber(data.code) ~= 1 then return result end
    if type(data.list) ~= "table" then
        result.ok = true
        return result
    end
    local seen = {}
    for _, it in ipairs(data.list) do
        if type(it) == "table" and it.id ~= nil then
            local id = tostring(it.id)
            local title = type(it.name) == "string" and it.name or ""
            if id ~= "" and not seen[id] then
                seen[id] = true
                result.items[#result.items + 1] = { gv_id = id, title = title }
            end
        end
    end
    result.ok = true
    return result
end

-- ============ 详情页（/GV{GV号}/）============

-- → { ok=bool, lines={ {label, episodes={ {gv, src, ep, label} }} } }
-- lines 按页面线路顺序（tab 与 anthology-list-box 按索引对应，tab 缺失时兜底「线路N」）；
-- episodes 保持页面顺序（实测升序即正片序）；ok = 至少一条线路有集数
function M.parse_detail(html)
    local result = { ok = false, lines = {} }
    if type(html) ~= "string" then return result end

    -- 线路标签：anthology-tab 到 anthology-list 之间（页头导航同为 swiper-slide，不锚定会混入；
    -- 两个 class 属性均为多值空格拼接，匹配不带闭合引号）
    local labels = {}
    local tab_start = html:find('class="anthology%-tab')
    if tab_start then
        local list_start = html:find('class="anthology%-list', tab_start)
        local region = html:sub(tab_start, list_start and list_start - 1 or #html)
        for a in region:gmatch('<a class="swiper%-slide">(.-)</a>') do
            local text = a:gsub('<span class="badge"[^>]*>.-</span>', "")
                :gsub("<[^>]->", "")
            text = decode_entities(text):gsub("^%s+", ""):gsub("%s+$", "")
            labels[#labels + 1] = text
        end
    end

    -- 逐线路集数：每个 ul.anthology-list-play 即一条线路（该 class 为集数列表专属，
    -- 不与页面其余区块碰撞；ul 内无嵌套 ul，非贪婪到 </ul> 即止）
    local idx = 0
    for block in html:gmatch('<ul class="anthology%-list%-play[^"]*">(.-)</ul>') do
        idx = idx + 1
        local line = { label = labels[idx] ~= "" and labels[idx] or ("线路" .. idx), episodes = {} }
        for gv, src, ep, raw in block:gmatch(
            '<a[^>]-href="/playGV(%d+)-(%d+)-(%d+)/?"[^>]*>(.-)</a>') do
            local label = decode_entities(raw:gsub("<[^>]->", ""))
                :gsub("^%s+", ""):gsub("%s+$", "")
            line.episodes[#line.episodes + 1] = {
                gv = gv, src = tonumber(src), ep = tonumber(ep), label = label,
            }
        end
        if #line.episodes > 0 then
            result.lines[#result.lines + 1] = line
        end
    end
    result.ok = #result.lines > 0
    return result
end

-- ============ 播放页（/playGV{GV}-{src}-{ep}/）============

-- → { ok=bool, m3u8, from }：m3u8=裸播放地址（getScrolling 只认裸 m3u8）、from=线路标记
-- （cht/chs/DB…）。encrypt 0/1/2 三档均处理；解出地址须为纯安全 ASCII（不含引号/反斜杠
-- 等需 JSON 转义的字符——调用方直接拼 {"play_url":"…"} body），不合法即整体失败
function M.parse_player(html)
    local result = { ok = false, m3u8 = nil, from = nil }
    if type(html) ~= "string" then return result end
    local data = extract_page_json(html, "player_aaaa")
    if type(data) ~= "table" or type(data.url) ~= "string" or data.url == "" then
        return result
    end
    local url = data.url
    local encrypt = tonumber(data.encrypt) or 0
    if encrypt == 2 then
        url = percent_decode(b64.decode(url))
    elseif encrypt == 1 then
        url = b64.decode(url)
    end
    if not url:match("^https?://[%w%.%/_%-]+$") then return result end
    result.m3u8 = url
    result.from = type(data.from) == "string" and data.from or nil
    result.ok = true
    return result
end

-- ============ 弹幕（getScrolling 响应 JSON）============

-- → { ok=bool, comments={ {time=秒, color=整数RGB, mode=1/4/5, text} } }
-- mode 映射：1滚动→1、2顶部→5、3底部→4（APlayer modeName 实锤），其余按滚动兜底；
-- ok=false = 接口错误（code≠1 / 非 JSON）；code=1 且 info=[] = 合法空（ok=true 零条）；
-- 畸形单条（缺 time/mode/content）跳过不击穿整批
local MODE_MAP = { [1] = 1, [2] = 5, [3] = 4 }

function M.parse_danmaku(json_string)
    local out = { ok = false, comments = {} }
    if type(json_string) ~= "string" then return out end
    local data = utils.parse_json(json_string)
    if type(data) ~= "table" or tonumber(data.code) ~= 1 then return out end
    out.ok = true
    if type(data.info) ~= "table" then return out end
    for _, e in ipairs(data.info) do
        local j = type(e) == "table" and e.scroll_json or nil
        if type(j) == "table" then
            local text = type(j.content) == "string" and j.content or ""
            local t = tonumber(j.time)
            local m = tonumber(j.mode)
            if text ~= "" and t and m then
                out.comments[#out.comments + 1] = {
                    time = t,
                    mode = MODE_MAP[m] or 1,
                    color = hex_color(type(j.style) == "table" and j.style.color or nil),
                    text = text,
                }
            end
        end
    end
    return out
end

return M
