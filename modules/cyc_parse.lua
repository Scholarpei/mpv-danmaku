-- 次元城（CYCity / cycani.org）搜索/分集/弹幕 JSON 的纯解析函数
-- （除 mp.utils 零 mp 依赖，单测直打；照 modules/ggl_parse.lua 同款口径）
-- 调用方：apis/cyc_search.lua、sites/cyc.lua
--
-- 接口形态（2026-10-14 实测，见 tests/fixtures/cyc_*）：
--   全部接口为 GET + 请求头 x-app-name: cyc_web（唯一必需头；无 UA/cookie/referer
--   校验，curl 直达）。缺头 → {"code":1000,"msg":"app_name is required"}。
--   搜索 GET https://www.cycani.org/api/videos/search?q=<kw>&page=1&page_size=24 —— JSON：
--     {"code":0,"data":{"list":[{"video_id":2964,"title":"葬送的芙莉莲",
--       "year":2023,"total":28,"remarks":"",…}],"pager":{…}}}；无结果 code=0 list=[]。
--     ⚠️ 英文关键词直达（english_title 参与匹配，"frieren" 搜到中文条目）——不接 TMDB。
--     多季番为独立 video 条目（S1/S2 各自 id），无 ezdmw 式复合集数问题。
--   分集 GET https://www.cycani.org/api/videos/{video_id}/sections
--       ?player_code=cychub&page={n}&page_size=100 —— JSON：
--     {"code":0,"data":{"list":[{"id":40100,"title":"第01集"},…],
--       "pager":{"page":1,"page_size":48,"total":1155}}}。
--     ⚠️ player_code 必须精确 cychub（其他值 404、缺失 1000）；page_size 上限 100
--     （>100 报 "PageSize must be 100 or less"，网页前端用 48）——长番（海贼王
--     1155 集）由调用方串行翻页取满 pager.total。剧场版单集同形态（title 第01集）。
--   弹幕 GET https://www.cycani.org/api/sections/{section_id}/danmaku —— JSON：
--     {"code":0,"data":{"count":862,"items":[{"id":…,"content":"三刷",
--       "time_point":1.736,"mode":"normal","color":16777215,
--       "create_time":"2025-06-24T17:00:03+08:00"},…]}}。
--     ⚠️ 全量单次返回无分页（page/offset 等参数被服务端忽略，count==items.length）；
--     time_point 为秒（float，实测大致升序，此处防御性再排）；color 为十进制整数
--     （非 hex 字符串，16777215=白）；mode 实测仅 "normal"（滚动）——防御性映射
--     top→5 / bottom→4 / 其余→1（照 ayf position 未知兜底口径）；HTTP 层 no-store
--     无 ETag（缓存由调用方自管）。合法空 = code=0 且 items=[]（该集确无弹幕，
--     实测站内弹幕覆盖率高难觅零条集）；code≠0 / 非 JSON = 接口错误两口径区分。
-- 弹幕挂 section_id（番剧级池，与播放线路无关——同一集不同线路解析共享弹幕）。
-- 域名轮换史（维护备忘）：主站 www.cycani.org；官方发布页 www.cycity.pro（换域名、
--   出新版第一时间更新，域名失效时查发布页）；API 与页面同域无独立接口域。

local utils = require("mp.utils")

local M = {}

-- ============ 搜索（/api/videos/search 响应 JSON）============

-- → { ok=bool, items={ {video_id, title, year, total} } }
-- ok 仅表示完成了解析流程（含无结果的空表）；code≠0 / 非 JSON 为接口错误 ok=false
function M.parse_search(json_string)
    local result = { ok = false, items = {} }
    if type(json_string) ~= "string" then return result end
    local data = utils.parse_json(json_string)
    if type(data) ~= "table" or tonumber(data.code) ~= 0 then return result end
    local list = type(data.data) == "table" and data.data.list or nil
    if type(list) ~= "table" then
        result.ok = true
        return result
    end
    for _, it in ipairs(list) do
        if type(it) == "table" and it.video_id ~= nil then
            result.items[#result.items + 1] = {
                video_id = tostring(it.video_id),
                title = type(it.title) == "string" and it.title or "",
                year = tonumber(it.year) or 0,
                total = tonumber(it.total) or 0,
            }
        end
    end
    result.ok = true
    return result
end

-- ============ 分集（/api/videos/{id}/sections 响应 JSON，单页）============

-- → { ok=bool, list={ {id, title} }, total }
-- total 取 pager.total（翻页终止条件；缺失时回退本页条数——单页短番照常可用）；
-- ok=false = 接口错误（code≠0 / 非 JSON）；list 空表可为合法（无正片）
function M.parse_sections(json_string)
    local result = { ok = false, list = {}, total = 0 }
    if type(json_string) ~= "string" then return result end
    local data = utils.parse_json(json_string)
    if type(data) ~= "table" or tonumber(data.code) ~= 0 then return result end
    result.ok = true
    local d = type(data.data) == "table" and data.data or {}
    local list = type(d.list) == "table" and d.list or {}
    for _, it in ipairs(list) do
        if type(it) == "table" and it.id ~= nil then
            result.list[#result.list + 1] = {
                id = tostring(it.id),
                title = type(it.title) == "string" and it.title or "",
            }
        end
    end
    local pager = type(d.pager) == "table" and d.pager or {}
    result.total = tonumber(pager.total) or #result.list
    return result
end

-- ============ 弹幕（/api/sections/{sid}/danmaku 响应 JSON）============

-- → { ok=bool, comments={ {time=秒, color=整数RGB, mode=1/4/5, text} } }
-- mode 映射："normal"→1 滚动、防御性 "top"→5 / "bottom"→4、其余按滚动兜底
-- （实测全站 normal，未见其他值）；color 十进制整数缺失兜底白 0xFFFFFF；
-- ok=false = 接口错误（code≠0 / 非 JSON）；code=0 且 items=[] = 合法空（ok=true 零条）；
-- 畸形单条（缺 content/time_point）跳过不击穿整批；time_point 防御性升序再排
local MODE_MAP = { normal = 1, top = 5, bottom = 4 }

function M.parse_danmaku(json_string)
    local raw = { ok = false, comments = {} }
    if type(json_string) ~= "string" then return raw end
    local data = utils.parse_json(json_string)
    if type(data) ~= "table" or tonumber(data.code) ~= 0 then return raw end
    raw.ok = true
    local items = type(data.data) == "table" and data.data.items or nil
    if type(items) ~= "table" then return raw end
    for _, e in ipairs(items) do
        if type(e) == "table" then
            local text = type(e.content) == "string" and e.content or ""
            local t = tonumber(e.time_point)
            if text ~= "" and t then
                local mode = type(e.mode) == "string" and MODE_MAP[e.mode] or 1
                raw.comments[#raw.comments + 1] = {
                    time = t,
                    mode = mode,
                    color = tonumber(e.color) or 0xFFFFFF,
                    text = text,
                }
            end
        end
    end
    -- 防御性升序（实测大致有序，不依赖服务端排序保证）
    table.sort(raw.comments, function(a, b) return a.time < b.time end)
    return raw
end

return M
