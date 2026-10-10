-- 芒果TV搜索/剧集列表的纯解析函数（无硬性 mp.* 依赖以便单元测试）
-- 调用方：apis/mgtv_search.lua
--
-- 接口形态（2026-10 实测）：
--   搜索 mobileso.bz.mgtv.com/aphone/search/rebirth/v2 → data.contents[]，
--     剧集条目 type=="mediaRebirth"（或 mediaRebirthV2）的 data[]：
--     {clipId, source, title, desc=["类型: 电视剧 / 2023 / 内地", "导演: …", "主演: …"], img}；
--     芒果版权 source 为 ""/imgo 且 clipId 非空；站外版权（source=qq 等）clipId 为空串 → 过滤
--   分集 pcweb.api.mgtv.com/variety/showlist（电视剧同用此接口）→ data：
--     {list[]: {video_id, src_clip_id, isnew('0'正片/'2'预告), t1(标题), t2(剧="第N集"/综艺=日期)},
--      tab_m[]: {m="202301"}（综艺按月分页，倒序；电视剧单月）}

local M = {}

-- 综艺衍生内容黑名单（命中任一即丢弃，只保留正片期）
local TITLE_BLACKLIST = {
    "彩蛋", "花絮", "预告", "抢先", "加更", "纯享", "衍生", "发布会", "幕后",
    "揭秘", "特辑", "未播", "轻量版", "看点", "片段", "花边", "独家",
    "名场面", "收官宴", "打包", "精简版",
}

-- desc[0] "类型: 电视剧 / 2023 / 内地" → {type_name, year}
local function parse_desc0(desc)
    local type_name, year = "剧集", nil
    local first = type(desc) == "table" and type(desc[1]) == "string" and desc[1] or ""
    if first ~= "" then
        local t = first:match("类型[:：]%s*([^/%s]+)")
        if t then type_name = t end
        year = tonumber(first:match("/%s*(%d%d%d%d)"))
    end
    return type_name, year
end

local function is_blacklisted(title)
    for _, kw in ipairs(TITLE_BLACKLIST) do
        if title:find(kw, 1, true) then return true end
    end
    return false
end

-- 搜索响应（已 parse_json 的 table）→ { ok=bool, items={ {clip_id,title,year,type_name} } }
-- 保留 type=mediaRebirth/mediaRebirthV2 组件内 source∈{"",imgo} 且 clipId 非空的条目；clipId 去重
function M.parse_search(d)
    local result = { ok = true, items = {} }
    if type(d) ~= "table" then
        return { ok = false, items = {} }
    end
    local data = d.data
    if type(data) ~= "table" or type(data.contents) ~= "table" then return result end

    local seen = {}
    for _, cont in ipairs(data.contents) do
        if type(cont) == "table" and (cont.type == "mediaRebirth" or cont.type == "mediaRebirthV2")
            and type(cont.data) == "table" then
            for _, it in ipairs(cont.data) do
                if type(it) == "table" and it.clipId and it.clipId ~= "" then
                    local src = it.source or ""
                    if (src == "" or src == "imgo") and type(it.title) == "string" then
                        local cid = tostring(it.clipId)
                        if not seen[cid] then
                            seen[cid] = true
                            local type_name, year = parse_desc0(it.desc)
                            table.insert(result.items, {
                                clip_id = cid,
                                title = it.title,
                                year = year or 0,
                                type_name = type_name,
                            })
                        end
                    end
                end
            end
        end
    end
    return result
end

-- showlist 响应 → { ok=bool, months={ "202301", ... }, episodes={ {video_id, t1, t2} } }
-- episodes 仅含本响应内的正片条目（src_clip_id 过滤 + isnew~="2" + 黑名单词）；
-- months 为 tab_m 的月份串（接口返回倒序，调用方自行决定正反序拼接）
function M.parse_showlist(d, collection_id)
    local result = { ok = true, months = {}, episodes = {} }
    if type(d) ~= "table" then
        return { ok = false, months = {}, episodes = {} }
    end
    local data = d.data
    if type(data) ~= "table" then return result end

    if type(data.tab_m) == "table" then
        for _, tab in ipairs(data.tab_m) do
            if type(tab) == "table" and tab.m then
                result.months[#result.months + 1] = tostring(tab.m)
            end
        end
    end

    if type(data.list) == "table" then
        for _, it in ipairs(data.list) do
            if type(it) == "table" and it.video_id
                and tostring(it.src_clip_id) == tostring(collection_id)
                and tostring(it.isnew) ~= "2" then
                local t1 = type(it.t1) == "string" and it.t1 or ""
                local t2 = type(it.t2) == "string" and it.t2 or ""
                if not is_blacklisted(t1) and t1 ~= "" then
                    table.insert(result.episodes, {
                        video_id = tostring(it.video_id),
                        t1 = t1,
                        t2 = t2,
                    })
                end
            end
        end
    end
    return result
end

-- 跨月合并后的分集菜单标题与排序：
--   电视剧（t2 形如 "第1集"）→「第N集 标题」；综艺（t2 为日期）→「第N期 日期 标题」
-- months 由 tab_m 倒序翻转为时间正序后逐月拼接；返回 { {video_id, title} }
function M.merge_month_episodes(month_eps_list)
    local merged = {}
    for _, eps in ipairs(month_eps_list) do
        for _, ep in ipairs(eps) do
            merged[#merged + 1] = ep
        end
    end
    local out = {}
    for i, ep in ipairs(merged) do
        local title
        if ep.t2:find("^第%d+集") then
            title = ep.t2 .. " " .. ep.t1
        elseif ep.t2:match("^%d%d%d%d%-%d%d%-%d%d$") then
            title = "第" .. i .. "期 " .. ep.t2 .. " " .. ep.t1
        else
            title = (ep.t2 ~= "" and (ep.t2 .. " ") or "") .. ep.t1
        end
        out[#out + 1] = { video_id = ep.video_id, title = title }
    end
    return out
end

return M
