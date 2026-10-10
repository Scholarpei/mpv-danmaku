-- 优酷搜索/剧集列表的纯解析函数（无硬性 mp.* 依赖以便单元测试）
-- 调用方：apis/youku_search.lua
--
-- 接口形态（2026-10 实测）：
--   搜索 search.youku.com/api/search → pageComponentList[].componentMap[<id>].data[]，
--     剧集卡片 componentId=="H5ShowCard"：{showId, titleDTO.displayName, isYouku, hasYouku,
--     sourceName, episodeTotal, feature("2018 · 电视剧 · 中国 · 78集全(完结)"), posterDTO.vThumbUrl}；
--     优酷版权内容 isYouku/hasYouku==1，站外版权（sourceName=腾讯等）二者均为 0/-1 → 过滤
--   分集 openapi.youku.com/v2/shows/videos.json → {total(字符串), videos[]}，
--     正片 seq==stage（花絮/预告 seq 递增但 stage 停留在最后正片），vid=id(base64)，
--     title/duration(秒字符串)/published("2018-12-25 21:54:00")

local M = {}

-- 去除搜索结果标题里的 HTML 标签与【】角标并修剪空白（冒号统一为全角）
local function clean_title(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("<[^>]->", "")
    s = s:gsub("【.-】", "")
    s = s:gsub(":", "：")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 标题黑名单：解读类/预告类栏目（danmu_api 同款策略，命中任一即丢弃）
local TITLE_BLACKLIST = {
    "中配版", "抢先看", "非正片", "解读", "揭秘", "赏析", "特辑", "花絮", "彩蛋", "预告",
}

-- feature "2018 · 电视剧 · 中国 · 78集全(完结)" → 年份（首个 19xx/20xx 数字）
local function feature_year(feature)
    if type(feature) ~= "string" then return nil end
    local y = feature:match("[12]%d%d%d")
    return tonumber(y)
end

-- feature 第二段 → 媒体类型（电视剧/电影/综艺/动漫…）；取不到回退"剧集"
local function feature_type(feature)
    if type(feature) ~= "string" then return "剧集" end
    local seg = feature:match("·%s*([^·]-)%s*·") or feature:match("^[^·]-·%s*([^%s·]+)")
    seg = seg and seg:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if seg ~= "" then return seg end
    return "剧集"
end

-- 搜索响应（已 parse_json 的 table）→ { ok=bool, items={ {show_id,title,year,type_name,episode_total} } }
-- 遍历全部组件的 H5ShowCard；仅保留优酷版权（isYouku==1 或 hasYouku==1）；
-- 按标题黑名单过滤栏目向结果；showId 为空或重复的丢弃
function M.parse_search(d)
    local result = { ok = true, items = {} }
    if type(d) ~= "table" then
        return { ok = false, items = {} }
    end
    if type(d.pageComponentList) ~= "table" then return result end

    local seen = {}
    for _, comp in ipairs(d.pageComponentList) do
        local cmap = type(comp) == "table" and comp.componentMap or nil
        if type(cmap) == "table" then
            for _, c in pairs(cmap) do
                if type(c) == "table" and c.componentId == "H5ShowCard"
                    and type(c.data) == "table" then
                    for _, it in ipairs(c.data) do
                        if type(it) == "table" and it.showId then
                            local is_yk = tonumber(it.isYouku) or 0
                            local has_yk = tonumber(it.hasYouku) or 0
                            local td = type(it.titleDTO) == "table" and it.titleDTO or {}
                            local title = clean_title(td.displayName)
                            local skip = false
                            for _, kw in ipairs(TITLE_BLACKLIST) do
                                if title:find(kw, 1, true) then skip = true break end
                            end
                            local sid = tostring(it.showId)
                            if is_yk == 1 or has_yk == 1 then
                                if not skip and title ~= "" and not seen[sid] then
                                    seen[sid] = true
                                    table.insert(result.items, {
                                        show_id = sid,
                                        title = title,
                                        year = feature_year(it.feature) or 0,
                                        type_name = feature_type(it.feature),
                                        episode_total = tonumber(it.episodeTotal) or 0,
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return result
end

-- 分集响应 → { ok=bool, total=number, episodes={ {vid,title,published} } }
-- 正片判定 seq==stage（花絮/预告的 stage 停留在末集不随 seq 递增）；total 为字符串需 tonumber
function M.parse_episodes(d)
    local result = { ok = true, total = 0, episodes = {} }
    if type(d) ~= "table" then
        return { ok = false, total = 0, episodes = {} }
    end
    result.total = tonumber(d.total) or 0
    if type(d.videos) ~= "table" then return result end

    for _, v in ipairs(d.videos) do
        if type(v) == "table" and v.id then
            local seq, stage = tonumber(v.seq), tonumber(v.stage)
            if seq ~= nil and stage ~= nil and seq == stage then
                table.insert(result.episodes, {
                    vid = tostring(v.id),
                    title = clean_title(v.title),
                    published = type(v.published) == "string" and v.published or "",
                })
            end
        end
    end
    return result
end

-- 分集菜单标题：电影→原标题；综艺→「第N期 日期 标题」；剧/动漫→「第N集 标题」
-- date_str 形如 "2018-12-25 21:54:00"，取日期部分
function M.format_episode_title(title, index, type_name, date_str)
    title = title or ""
    if type_name == "电影" then
        return title ~= "" and title or ("第" .. index .. "集")
    end
    local date_part = type(date_str) == "string" and date_str:match("^(%d%d%d%d%-%d%d%-%d%d)") or ""
    if type_name == "综艺" then
        local period = title:match("第(%d+)期")
        local n = period or tostring(index)
        local prefix = "第" .. n .. "期" .. (date_part ~= "" and (" " .. date_part) or "")
        -- 标题自带「第N期」时避免重复
        if period and title:find("第" .. period .. "期", 1, true) then
            return prefix .. " " .. title:gsub("^第%d+期%s*", "")
        end
        return prefix .. " " .. title
    end
    -- 电视剧/动漫/其他
    if title:find("^第%d+集") then
        return title
    end
    return "第" .. index .. "集 " .. title
end

return M
