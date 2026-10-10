-- animeko（open-ani 社区弹幕）搜索/分集/弹幕的纯解析函数（无硬性 mp.* 依赖以便单元测试）
-- 调用方：apis/animeko_search.lua、sites/animeko.lua
--
-- 接口形态（2026-10 实测）：
--   搜索 POST api.bgm.tv/v0/search/subjects（body {keyword, filter={type=[2]}}，
--     UA 需自识别——bgm.tv 社区礼仪）→ data[]：{id, name, name_cn, date("2023-09-29"), images.common}
--   分集 GET <node>/v2/subjects/<subjectId> → episodes[]：
--     {episodeId, sort, type("MAIN"|"ED"|"OP"|…), name, nameCn}；仅 MAIN 为正片
--   弹幕 GET <node>/v1/danmaku/<episodeId> → 顶层 danmakuList[]：
--     {id, senderId, danmakuInfo={playTime(毫秒), location("NORMAL"|"TOP"|"BOTTOM"),
--      color(整数, -1 表示默认), text}}——注意 danmakuList 在顶层而非 data 下

local M = {}

-- location → dandanplay 模式（1滚动/5顶部/4底部）
local LOCATION_MODE = {
    NORMAL = 1,
    TOP = 5,
    BOTTOM = 4,
}

-- bgm.tv 搜索响应 → { ok=bool, items={ {subject_id,title,year} } }
-- 标题优先 name_cn；date 取年份
function M.parse_search(d)
    local result = { ok = true, items = {} }
    if type(d) ~= "table" or type(d.data) ~= "table" then return result end
    for _, it in ipairs(d.data) do
        if type(it) == "table" and it.id then
            local title = type(it.name_cn) == "string" and it.name_cn ~= ""
                and it.name_cn or it.name
            if type(title) == "string" and title ~= "" then
                local year = 0
                if type(it.date) == "string" then
                    year = tonumber(it.date:match("^(%d%d%d%d)")) or 0
                end
                table.insert(result.items, {
                    subject_id = tostring(it.id),
                    title = title,
                    year = year,
                })
            end
        end
    end
    return result
end

-- v2/subjects 响应 → { ok=bool, title=string, episodes={ {episode_id,title} } }
-- 仅保留 type=="MAIN" 的正片，按返回序（sort 递增）即话数编号
function M.parse_subject(d)
    local result = { ok = true, title = "", episodes = {} }
    if type(d) ~= "table" then
        return { ok = false, episodes = {} }
    end
    result.title = type(d.nameCn) == "string" and d.nameCn ~= "" and d.nameCn
        or (type(d.title) == "string" and d.title or "")
    if type(d.episodes) ~= "table" then return result end

    for _, e in ipairs(d.episodes) do
        if type(e) == "table" and e.episodeId and e.type == "MAIN" then
            local title = type(e.nameCn) == "string" and e.nameCn ~= "" and e.nameCn
                or (type(e.name) == "string" and e.name or "")
            table.insert(result.episodes, {
                episode_id = tostring(e.episodeId),
                title = title,
            })
        end
    end
    return result
end

-- v1/danmaku 响应 → { time=秒, mode=1|4|5, color=整数, text=字符串 } 列表（sites 加载器用）
-- color -1 视为默认白；playTime 毫秒转秒
function M.parse_danmaku_list(d)
    local out = {}
    if type(d) ~= "table" or type(d.danmakuList) ~= "table" then return out end
    for _, item in ipairs(d.danmakuList) do
        local info = type(item) == "table" and item.danmakuInfo or nil
        if type(info) == "table" and type(info.text) == "string" then
            local t = tonumber(info.playTime) or 0
            local color = tonumber(info.color)
            if color == nil or color < 0 then color = 16777215 end
            out[#out + 1] = {
                time = t / 1000,
                mode = LOCATION_MODE[info.location] or 1,
                color = color,
                text = info.text,
            }
        end
    end
    return out
end

return M
