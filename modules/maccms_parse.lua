-- MacCMS（苹果CMS10）采集接口的纯解析函数（照 bilibili_match.lua 无 mp.* 依赖以便单元测试）
-- 调用方：apis/maccms.lua（|mac 搜索后缀的搜索/剧集列表/续载流程）
--
-- 采集接口标准形态：GET {站根}/api.php/provide/vod/?ac=detail&wd={关键词}（搜索）或 &ids={id}（按id取详情）
-- 剧集藏在 vod_play_from / vod_play_url 两个平行字符串里：
--   两者都以 $$$ 分隔多个播放来源组，组内以 # 分隔各集，每集为 标题$链接
--   例：vod_play_from="qq$$$m3u8"
--       vod_play_url="第01集$https://v.qq.com/x/cover/a.html#第02集$...$$$第01集$/vod/a.m3u8#..."
-- 注意：$$$ / # / $ 都是字面量分隔符，一律用 plain find 切分（Lua pattern 中 $ 是锚点）

local M = {}

local function trim(s)
    if type(s) ~= "string" then return nil end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 按 plain 分隔符切分，保留空段（调用方自行决定是否过滤，保证平行字符串的下标对齐）
local function split_by(s, sep)
    local parts = {}
    if type(s) ~= "string" or s == "" then return parts end
    local start = 1
    while true do
        local pos = s:find(sep, start, true)
        if not pos then
            parts[#parts + 1] = s:sub(start)
            break
        end
        parts[#parts + 1] = s:sub(start, pos - 1)
        start = pos + #sep
    end
    return parts
end

-- "$$$" 分隔的组名列表；空组跳过（仅用于展示，不参与 from/url 对齐）
function M.split_groups(s)
    local groups = {}
    for _, seg in ipairs(split_by(s, "$$$")) do
        local name = trim(seg)
        if name and name ~= "" then
            groups[#groups + 1] = name
        end
    end
    return groups
end

-- 单组播放串（# 分集、每集 标题$链接）→ { {title=, url=}, ... }
-- 按【第一个】$ 切分防链接内 $ 误切；无 $ 的段视为纯链接（标题空）；空段跳过
function M.split_episodes(s)
    local eps = {}
    for _, seg in ipairs(split_by(s, "#")) do
        seg = trim(seg) or ""
        if seg ~= "" then
            local title, url
            local pos = seg:find("$", 1, true)
            if pos then
                title = trim(seg:sub(1, pos - 1)) or ""
                url = trim(seg:sub(pos + 1)) or ""
            else
                title = ""
                url = seg
            end
            if url ~= "" then
                eps[#eps + 1] = { title = title, url = url }
            end
        end
    end
    return eps
end

-- 取响应中的原始 vod 数组（保留 vod_play_from/vod_play_url 等全部字段，供 parse_play_sources 使用）
-- 兼容 list 挂在根或 .data 下两种封装
function M.get_raw_list(d)
    if type(d) ~= "table" then return nil end
    if type(d.list) == "table" then return d.list end
    if type(d.data) == "table" and type(d.data.list) == "table" then return d.data.list end
    return nil
end

-- 采集搜索/详情响应（已 parse_json 的 table）→ { {vod_id=, vod_name=, vod_year=, vod_class=, vod_area=} }
-- 兼容 list 挂在根或 .data 下两种封装；vod_id/vod_year 有的站返回字符串，统一 tonumber 容错
function M.parse_vod_list(d)
    local result = {}
    local list = M.get_raw_list(d)
    if not list then return result end
    for _, vod in ipairs(list) do
        if type(vod) == "table" and vod.vod_id ~= nil and vod.vod_name then
            result[#result + 1] = {
                vod_id = tonumber(vod.vod_id) or vod.vod_id,
                vod_name = tostring(vod.vod_name),
                vod_year = tonumber(vod.vod_year) or 0,
                vod_class = type(vod.vod_class) == "string" and vod.vod_class or "",
                vod_area = type(vod.vod_area) == "string" and vod.vod_area or "",
            }
        end
    end
    return result
end

-- vod 条目 → { from={组名,...}, urls={ {title=,url=},... 每组一个列表 } }
-- vod_play_from 与 vod_play_url 均按 $$$ 切分（保留空段保证下标对齐）后按位配对，
-- 两组数不齐按小者截断（防脏数据）；无有效集数的组剔除，空组名回退「来源N」
function M.parse_play_sources(vod)
    local result = { from = {}, urls = {} }
    if type(vod) ~= "table" then return result end
    local from_groups = split_by(vod.vod_play_from, "$$$")
    local url_groups = split_by(vod.vod_play_url, "$$$")

    local count = math.min(#from_groups, #url_groups)
    for i = 1, count do
        local eps = M.split_episodes(url_groups[i])
        if #eps > 0 then
            local name = trim(from_groups[i]) or ""
            if name == "" then
                name = "来源" .. (#result.from + 1)
            end
            result.from[#result.from + 1] = name
            result.urls[#result.urls + 1] = eps
        end
    end
    return result
end

-- 按 1 基索引取某组某集；越界或 play 无效返回 nil
function M.get_episode(play, group_idx, ep_idx)
    if type(play) ~= "table" then return nil end
    local eps = play.urls and play.urls[group_idx]
    if type(eps) ~= "table" then return nil end
    return eps[ep_idx]
end

return M
