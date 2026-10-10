-- B站 WBI 签名与搜索/分集解析的纯函数（无硬性 mp.* 依赖以便单元测试）
-- 调用方：apis/bilibili_search.lua
--
-- WBI 签名规范来自 bilibili-API-collect 社区公开文档（SocialSisterYi）：
--   GET /x/web-interface/nav → data.wbi_img.{img_url,sub_url} 取文件名（去 .png）得 imgKey/subKey；
--   mixinKey = (imgKey..subKey) 按固定 64 项置换表重排取前 32 字符；
--   请求参数加 wts（秒级时间戳）后按 key 字典序 k=v&… 拼接（encodeURIComponent 语义，
--   即 !'()* 不编码），w_rid = md5(拼接串 .. mixinKey)。
-- 接口形态（2026-10 实测）：
--   搜索 /x/web-interface/wbi/search/type?search_type=media_bangumi|media_ft →
--     data.result[]：{season_id, title(带<em>高亮), org_title, season_type_name,
--     styles("漫画改/奇幻/…"), pubtime(unix秒), index_show("全28话"), cover, media_score}；
--     media_ft 影视区当前内容稀缺，常空
--   分集 /pgc/view/web/season?season_id= → result.episodes[]：
--     {id(ep), cid, title(集号字符串), long_title, duration(ms), section_type}；
--     正片 section_type==0（预告为 1），同一集号可能出现多版本，按 section_type 过滤后即连续

local md5 = require("modules/md5")

local M = {}

-- 置换表（社区公开的固定值）
local MIXIN_TAB = {
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
    61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
    36, 20, 34, 44, 52,
}

-- nav 接口不可用时的兜底 mixinKey（社区公开的长期可用值）
M.FALLBACK_MIXIN = "dba4a5925b345b4598b7452c75070bca"

-- imgKey/subKey → mixinKey
function M.mixin_key(img_key, sub_key)
    local raw = tostring(img_key or "") .. tostring(sub_key or "")
    local out = {}
    for i = 1, #MIXIN_TAB do
        local idx = MIXIN_TAB[i]
        if idx < #raw then
            out[#out + 1] = raw:sub(idx + 1, idx + 1)
        end
    end
    return table.concat(out):sub(1, 32)
end

-- wbi_img 的 URL（…/xxx.png）→ key
function M.key_from_url(url)
    if type(url) ~= "string" then return nil end
    local name = url:match("([^/]+)%.%w+$")
    return name ~= "" and name or nil
end

-- encodeURIComponent 语义（!'()* 不编码；比 utils.url_encode 多保留这五个字符）
function M.encode_uri_component(s)
    s = tostring(s or "")
    return (s:gsub("([^%w%-%.%_%~%!%*%'%(%)])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- 参数表 + mixinKey → 签名后的 query string（含 wts/w_rid）
-- params 为 {k=v} 平面表；wts 由调用方传入（便于测试确定性）
function M.signed_query(params, mixin_key, wts)
    local merged = {}
    for k, v in pairs(params) do
        merged[k] = tostring(v)
    end
    merged.wts = tostring(wts)
    local keys = {}
    for k in pairs(merged) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = M.encode_uri_component(k) .. "=" .. M.encode_uri_component(merged[k])
    end
    local qs = table.concat(parts, "&")
    local w_rid = md5.sum(qs .. mixin_key)
    return qs .. "&w_rid=" .. w_rid
end

-- 去除搜索标题 <em> 高亮标签
local function strip_em(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("<[^>]->", ""))
end

-- pubtime(unix 秒) → 年份数字；无效返回 0（os.date 依赖平台，%Y 四位年份通用）
local function pubtime_year(t)
    local n = tonumber(t)
    if not n or n <= 0 then return 0 end
    return tonumber(os.date("!%Y", n)) or 0
end

-- nav 响应 → mixinKey；取不到返回 nil
function M.parse_nav(d)
    if type(d) ~= "table" or type(d.data) ~= "table"
        or type(d.data.wbi_img) ~= "table" then
        return nil
    end
    local img_key = M.key_from_url(d.data.wbi_img.img_url)
    local sub_key = M.key_from_url(d.data.wbi_img.sub_url)
    if not img_key or not sub_key then return nil end
    return M.mixin_key(img_key, sub_key)
end

-- 搜索响应 → { ok=bool, items={ {season_id,title,year,type_name,index_show} } }
-- code==0 且 data.result 为数组才产出条目；season_id 去重（两路 search_type 会重复）
function M.parse_search(d)
    local result = { ok = true, items = {} }
    if type(d) ~= "table" then
        return { ok = false, items = {} }
    end
    if tonumber(d.code) ~= 0 then
        return { ok = false, code = tonumber(d.code), items = {} }
    end
    local data = d.data
    if type(data) ~= "table" or type(data.result) ~= "table" then return result end

    for _, r in ipairs(data.result) do
        if type(r) == "table" and r.season_id then
            local sid = tostring(r.season_id)
            local title = strip_em(r.title)
            if title ~= "" then
                local type_name = r.season_type_name
                if type(type_name) ~= "string" or type_name == "" then
                    type_name = "番剧"
                end
                table.insert(result.items, {
                    season_id = sid,
                    title = title,
                    org_title = strip_em(r.org_title),
                    year = pubtime_year(r.pubtime),
                    type_name = type_name,
                    index_show = type(r.index_show) == "string" and r.index_show or "",
                })
            end
        end
    end
    return result
end

-- pgc season 响应 → { ok=bool, title=string, episodes={ {ep_id,cid,title,long_title} } }
-- 仅保留 section_type==0 的正片（预告/花絮为 1）；分集按数组序即集数编号
function M.parse_season(d)
    local result = { ok = true, title = "", episodes = {} }
    if type(d) ~= "table" then
        return { ok = false, episodes = {} }
    end
    if tonumber(d.code) ~= 0 then
        return { ok = false, code = tonumber(d.code), episodes = {} }
    end
    local r = d.result
    if type(r) ~= "table" then return result end
    result.title = strip_em(r.title)

    if type(r.episodes) == "table" then
        for _, e in ipairs(r.episodes) do
            if type(e) == "table" and e.id and tonumber(e.section_type or 0) == 0 then
                table.insert(result.episodes, {
                    ep_id = tostring(e.id),
                    cid = tostring(e.cid or ""),
                    title = type(e.title) == "string" and e.title or "",
                    long_title = strip_em(e.long_title),
                })
            end
        end
    end
    return result
end

return M
