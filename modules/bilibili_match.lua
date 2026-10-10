-- B站分P标题匹配引擎（文件夹级弹幕记忆的核心算法）
-- 纯 Lua 无 mp.* 依赖以便单元测试；调用方 sites/bilibili.lua
--
-- 输入：pagelist 的分P数组 {{page=, part=, duration=}, ...} 与本地文件的季/集/时长、
--       记忆锚点（上次匹配到的 page 与当时的集数/季数）
-- 输出：{page=, part=, via="title"|"duration"|"delta"} 或 nil（真歧义/无候选）
--
-- 匹配优先级：标题精确匹配（季+集打分）> 时长校验裁决 > 锚点 p+集数差 仲裁
-- 编号一致性按锚点相对偏移校验：合并多季合集的分P编号体系可与本地集数差常量偏移
-- 本地文件名普遍解析不出季数（如 "Title S3 - 09"），锚点是可靠性的兜底主力

local M = {}

-- 特殊篇标记：命中则降权；delta 落点为特殊篇时拒绝
-- 拉丁标记用 %f 词边界防误伤（spy×family 不含 sp；cm 因 "5cm" 类误伤风险不收录）
local SPECIAL_CJK = { "特别篇", "番外" }
local SPECIAL_LATIN = { "ova", "oad", "sp", "pv", "ncop", "nced" }

local function is_special(t)
    local lower = t:lower()
    for _, mark in ipairs(SPECIAL_CJK) do
        if lower:find(mark, 1, true) then return true end
    end
    for _, mark in ipairs(SPECIAL_LATIN) do
        if lower:find("%f[%a]" .. mark .. "%f[%A]") then return true end
    end
    return false
end

-- 解析分P标题 -> season|nil, episode|nil, special|bool
-- 模式按序尝试，首个命中即返回；无命中返回 nil,nil,false（如 "PV"、"上集"、"Part 1"）
function M.parse_part_title(title)
    if type(title) ~= "string" then return nil, nil, false end
    local t = title:gsub("^%s+", ""):gsub("%s+$", "")
    if t == "" then return nil, nil, false end

    local season, episode
    -- 带季形式
    season, episode = t:match("^【%s*[Ss](%d+)%s*】%s*(%d+)")            -- 【S3】09
    if not season then
        season, episode = t:match("^%[?%s*[Ss](%d+)%s*[%-%s:.]*%s*[Ee]%s*(%d+)") -- S03E09 / S3 E9
    end
    if not season then
        season, episode = t:match("^第%s*(%d+)%s*[季部].*第%s*(%d+)%s*[话集回]") -- 第2季 第05话
    end
    if not season then
        season, episode = t:match("^%[?%s*[Ss](%d+)%s*%-?%s*(%d+)%s*$")  -- S3-09（无 E 形式）
    end
    if season then
        return tonumber(season), tonumber(episode), is_special(t)
    end

    -- 仅集数形式
    episode = t:match("^%s*(%d+)%s*$")                                   -- 9 / 09
        or t:match("^%s*(%d+)%s*[（(%.%[%s]")                            -- 24（OVA） / 01 加长版
        or t:match("^%s*第%s*(%d+)%s*[话集回]")                           -- 第12话
        or t:match("^%s*[Ee][Pp]?%s*(%d+)")                              -- EP05 / E5
    if episode then
        return nil, tonumber(episode), is_special(t)
    end
    return nil, nil, false
end

-- 在分P数组中为当前集寻找最佳匹配
-- opts = {
--   parts = {{page=, part=, duration=}, ...},   -- pagelist 的 data 数组
--   season, episode,                            -- parse_title() 解析的本地季/集（季可为 nil）
--   anchor_page, anchor_episode, anchor_season, -- 记忆锚点（上次匹配的 page 与当时集数/季数）
--   duration,                                   -- 本地视频时长（秒，用于校验）
-- }
function M.match_bilibili_part(opts)
    local episode = opts.episode
    if episode == nil then return nil end
    local season = opts.season
    local duration = opts.duration
    local parts = opts.parts or {}
    local anchor_page, anchor_episode, anchor_season =
        opts.anchor_page, opts.anchor_episode, opts.anchor_season

    -- page 字段 → 分P 索引（正常分P数组下标即页号，此处按字段容错非常规列表）
    local by_page = {}
    for _, part in ipairs(parts) do
        if part.page ~= nil then by_page[part.page] = part end
    end

    -- 锚点分P的标题编号 pe0：合并多季合集里分P编号体系与本地集数体系可差一个
    -- 常量偏移（p13 标题 "13" ↔ 本地第79集），pe0 是推算该偏移的基准。
    -- 锚点页不在列表或标题不可解析时为 nil，各处退回保守行为
    local anchor_pe = nil
    if anchor_page ~= nil then
        local ap = by_page[anchor_page]
        if ap ~= nil then
            local _, pe0 = M.parse_part_title(ap.part or "")
            anchor_pe = pe0
        end
    end

    -- 锚点差值：p0 + (当前集 - 锚点集)。落点存在、集数不矛盾、非特殊篇、时长不离谱才收
    -- 时长硬门 600s：容纳 BD/WEB 等不同剪辑的时长漂移，仍拦截 MAD/PV 类短分P
    local function delta_result()
        if anchor_page == nil or anchor_episode == nil then return nil end
        local p = anchor_page + (episode - anchor_episode)
        local target = by_page[p]
        if target == nil then return nil end
        local _, pe, special = M.parse_part_title(target.part or "")
        if pe ~= nil then
            -- 编号一致性（锚点相对）：pe 应等于 pe0 + 集数差；pe0 未知时退回
            -- 与本地集数直接比较（旧行为，保守）
            local expected = anchor_pe ~= nil
                and (anchor_pe + episode - anchor_episode) or episode
            if pe ~= expected then return nil end
        end
        if special then return nil end
        if duration and target.duration
            and math.abs(target.duration - duration) > 600 then return nil end
        return { page = p, part = target.part, via = "delta" }
    end

    -- 收集集数相等的候选并打分
    local cands = {}
    for _, part in ipairs(parts) do
        local ps, pe, special = M.parse_part_title(part.part or "")
        if pe ~= nil and pe == episode then
            -- 硬排除：分P显式季与本地季矛盾
            if not (ps ~= nil and season ~= nil and ps ~= season) then
                local score = 0
                if ps ~= nil and season ~= nil then
                    score = score + 3                                       -- 显式季 == 本地季
                elseif ps == nil and anchor_season ~= nil and anchor_season == season then
                    score = score + 2                                       -- 裸标题，锚点季已校准
                end
                if special then score = score - 2 end
                local dd = nil
                if duration and part.duration then
                    dd = math.abs(part.duration - duration)
                    if dd <= 120 then score = score + 4
                    elseif dd > 300 then score = score - 6 end
                end
                if anchor_page ~= nil and part.page == anchor_page then
                    score = score + 6                                       -- 同集重放
                end
                table.insert(cands, { page = part.page, part = part.part,
                                      score = score, dd = dd })
            end
        end
    end

    if #cands == 0 then return delta_result() end

    if #cands == 1 then
        local c = cands[1]
        -- 唯一候选但时长严重矛盾（且非锚点重放）→ 交给锚点差值兜底判定
        if c.dd ~= nil and c.dd > 300 and c.page ~= anchor_page then
            return delta_result()
        end
        -- 锚点证明两套编号体系存在常量偏移（pe0 ≠ 锚点集数）时，唯一标题候选
        -- 可能是另一体系的数字巧合（合并季合集里 "02" 既是 p2 也是 p14 的编号），
        -- 优先锚点差值落点；delta 不成立（越界/特殊篇/时长门/编号不一致）仍收标题候选
        if anchor_pe ~= nil and anchor_episode ~= nil and anchor_pe ~= anchor_episode then
            local d = delta_result()
            if d ~= nil and d.page ~= c.page then return d end
        end
        return { page = c.page, part = c.part, via = "title" }
    end

    -- score 降序、时长差升序（nil 最后）、page 升序
    table.sort(cands, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        local add, bdd = a.dd or math.huge, b.dd or math.huge
        if add ~= bdd then return add < bdd end
        return a.page < b.page
    end)

    local top = cands[1]
    -- 明显领先第二名 → 直接收
    if top.score >= cands[2].score + 3 then
        return { page = top.page, part = top.part, via = "title" }
    end
    -- 时长打破平局：top 在容差内而第二名不在
    if top.dd ~= nil and top.dd <= 120 and (cands[2].dd == nil or cands[2].dd > 120) then
        return { page = top.page, part = top.part, via = "duration" }
    end
    -- 锚点差值仲裁：落点在同最高分的并列集合内即收
    local d = delta_result()
    if d ~= nil then
        for _, c in ipairs(cands) do
            if c.score == top.score and c.page == d.page then return d end
        end
    end
    return nil
end

return M
