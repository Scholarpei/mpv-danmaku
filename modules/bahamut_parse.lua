-- 巴哈姆特动画疯搜索/分集的纯解析函数（无硬性 mp.* 依赖以便单元测试）
-- 调用方：apis/bahamut_search.lua
--
-- 接口形态（2026-10 实测；分集接口对大陆直连 IP 受限，需代理环境）：
--   搜索 api.gamer.com.tw/mobile_app/anime/v1/search.php?kw=（iOS App UA）→
--     顶层 anime[]：{video_sn, title, info("年份：2026/01 共 10 集"), cover, score}；
--     关键词需繁体中文（简体命中率低，调用方负责简→繁）
--   分集 api.gamer.com.tw/anime/v1/video.php?videoSn=（iOS App UA）→
--     data.data.anime：{animeSn, title, totalEpisode, episodes}，episodes 为
--     对象（键 "0","1"…代表季度/分组）取 "0" 否则首个值 → [{episode, videoSn}]

local M = {}

-- info "年份：2026/01 共 10 集" → 年份；无年份返回 0
local function info_year(info)
    if type(info) ~= "string" then return 0 end
    return tonumber(info:match("(%d%d%d%d)")) or 0
end

-- 搜索响应 → { ok=bool, items={ {video_sn,title,year} } }
-- 巴哈搜索每季一条；标题去重；无条目时 ok 仍为 true（区分接口错误与无结果）
function M.parse_search(d)
    local result = { ok = true, items = {} }
    if type(d) ~= "table" or type(d.anime) ~= "table" then
        return { ok = type(d) == "table", items = {} }
    end
    local seen = {}
    for _, a in ipairs(d.anime) do
        if type(a) == "table" and a.video_sn then
            local sn = tostring(a.video_sn)
            local title = type(a.title) == "string" and a.title or ""
            if sn ~= "" and title ~= "" and not seen[sn] then
                seen[sn] = true
                table.insert(result.items, {
                    video_sn = sn,
                    title = title,
                    year = info_year(a.info),
                })
            end
        end
    end
    return result
end

-- video.php 响应 → { ok=bool, title=string, episodes={ {video_sn,episode} } }
-- 响应有两种深度形态（{data:{data:{video,anime}}} 与 {data:{video,anime}}}），均兼容；
-- episodes 为对象时取键 "0"（多键时其余为重复分组的其他版本，拍平会重复）；
-- 结构缺失/受限（任意层断层或 anime 无分集）一律 ok=false + restricted=true（调用方重试后提示）
function M.parse_video_info(d)
    local result = { ok = true, title = "", episodes = {} }
    if type(d) ~= "table" then
        return { ok = false, restricted = true, episodes = {} }
    end
    local data = d.data
    if type(data) ~= "table" then
        return { ok = false, restricted = true, episodes = {} }
    end
    -- 双形态：优先取两层（data.data），无则 data 本身即内层
    local inner = type(data.data) == "table" and data.data or data
    local anime = inner.anime
    if type(anime) ~= "table" or type(anime.episodes) ~= "table" then
        return { ok = false, restricted = true, episodes = {} }
    end
    result.title = type(anime.title) == "string" and anime.title or ""

    local eps = anime.episodes
    local list = nil
    if type(eps["0"]) == "table" then
        list = eps["0"]
    else
        for _, v in pairs(eps) do
            if type(v) == "table" then
                list = v
                break
            end
        end
    end
    for _, e in ipairs(list or {}) do
        if type(e) == "table" and e.videoSn then
            table.insert(result.episodes, {
                video_sn = tostring(e.videoSn),
                episode = e.episode,
            })
        end
    end
    if #result.episodes == 0 then
        return { ok = false, restricted = true, episodes = {} }
    end
    return result
end

return M
