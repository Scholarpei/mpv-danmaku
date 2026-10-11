-- 跨源弹幕时间轴对齐（纯算法模块，无 mp.* 依赖，可单测）
-- 多源叠加时不同平台的片头/剪辑差异会使各源弹幕时间戳整体错位（如巴哈源比本地
-- 晚 90 秒）。本模块按「同文本弹幕的出现时间差」投票统计全局偏移量，把各源时间轴
-- 对齐到同一基准：基准源建 归一化文本→最早时间 锚点表，其他源每条弹幕文本命中
-- 锚点即给 round(t_src - t_base) 投一票，得票最多的偏移过三重门槛后整源平移。
--
-- 算法思路参考 huangxd-/danmu_api 的 alignSourceTimelines（AGPL-3.0），此处为独立
-- Lua 重实现：基准源从「固定 dandan」推广为「弹幕条数最多的源」（锚点统计最稳，
-- 且无需在数据结构里标记主源）；JS Map 先插入者胜的平票规则改为取最小偏移，
-- 保证 pairs 序不定环境下的确定性。
--
-- 输入约定：entries 的 time 为「生效时间」（调用方已叠加手动延迟），因此用户手动
-- 补偿过的源漂移≈0 不会被二次平移；输出 shifts 为瞬态校正值（+于生效时间），
-- 由调用方应用并钳 0，不落历史。
--
-- 调用方：modules/parse.lua（收集/导出前的 compute_timeline_alignment）

local M = {}

-- 门槛常量（经验值，与参考实现一致）：
local EFFECTIVE_RATIO  = 0.05  -- 有效票率：最佳偏移票数 / 两源较小条数
local CONSENSUS_RATIO  = 0.15  -- 集中度：最佳偏移票数 / 文本命中条数
local OFFSET_THRESHOLD = 1     -- 触发整源平移的最小偏移（秒）

-- CJK 标点/引号/括号/全角空格。多字节字符不能进 Lua 字节字符类（会把 UTF-8 字节
-- 拆开误伤汉字），须逐字面 gsub；UTF-8 连续字节均 >=0x80，不含 pattern 魔法字符
local CJK_PUNCTS = {
    "，", "。", "！", "？", "、", "；", "：",
    "“", "”", "‘", "’",
    "（", "）", "《", "》", "【", "】", "「", "」", "『", "』",
    "·", "—", "–", "…", "～", "　",
    "＜", "＞", "＝", "＋", "－", "＊", "／", "＼", "＠", "＃", "＆", "％", "｜",
}

-- 归一化文本（跨源匹配键）：transform（简繁归一）→ 去 ASCII 空白标点 + CJK 标点
-- → ASCII 小写。纯标点/空白归一后为空则返回 nil（不参与匹配）
local function normalize_text(text, transform)
    if type(text) ~= "string" or text == "" then return nil end
    if transform then
        text = transform(text)
        if type(text) ~= "string" or text == "" then return nil end
    end
    text = text:gsub("[%s%p]", "")
    for i = 1, #CJK_PUNCTS do
        text = text:gsub(CJK_PUNCTS[i], "")
    end
    if text == "" then return nil end
    return text:lower()
end

-- 计算各源对齐校正量。
-- lists: { {url=..., provider=..., entries={{time=生效秒, text=原文}, ...}}, ... }
-- opts : { transform=fn(文本归一回调,可选), min_match_ratio=0~1(默认 0.3，实抓校准) }
-- 返回 : { shifts = {[url]=平移秒(负=提前)}, baseline = url, diag = {...} }
--        diag 每源一项：{url, provider, drift(检出漂移), votes, match_count,
--                        applied, reason}，供调用方写日志
function M.compute(lists, opts)
    opts = opts or {}
    local result = { shifts = {}, baseline = nil, diag = {} }

    -- 参与对齐的源（有条数者），按 URL 升序保证遍历确定性
    local active = {}
    for _, item in ipairs(lists or {}) do
        if item and item.url and type(item.entries) == "table" and #item.entries > 0 then
            active[#active + 1] = item
        end
    end
    if #active < 2 then return result end
    table.sort(active, function(a, b) return a.url < b.url end)

    -- 基准源 = 弹幕条数最多（active 已按 URL 升序，平票取字典序最小）
    local baseline = active[1]
    for _, item in ipairs(active) do
        if #item.entries > #baseline.entries then baseline = item end
    end
    result.baseline = baseline.url

    -- 默认 0.3：实抓校准值（见 options.lua timeline_align_min_match 注释）
    local min_match_ratio = tonumber(opts.min_match_ratio)
    if min_match_ratio == nil or min_match_ratio <= 0 or min_match_ratio > 1 then
        min_match_ratio = 0.3
    end

    -- 基准锚点表：归一化文本 → 最早出现时间（同文本取最早，与参考实现一致）
    local base_map = {}
    for _, e in ipairs(baseline.entries) do
        local key = normalize_text(e.text, opts.transform)
        if key then
            local t = tonumber(e.time) or 0
            if base_map[key] == nil or t < base_map[key] then base_map[key] = t end
        end
    end

    for _, item in ipairs(active) do
        if item.url ~= baseline.url then
            local votes, offsets = {}, {}
            local match_count = 0
            for _, e in ipairs(item.entries) do
                local key = normalize_text(e.text, opts.transform)
                if key and base_map[key] ~= nil then
                    match_count = match_count + 1
                    -- floor(x+0.5) 与 JS Math.round 一致（含负数 .5 边界）
                    local drift = math.floor((tonumber(e.time) or 0) - base_map[key] + 0.5)
                    if votes[drift] == nil then
                        votes[drift] = 0
                        offsets[#offsets + 1] = drift
                    end
                    votes[drift] = votes[drift] + 1
                end
            end

            -- 最佳偏移：候选升序遍历、严格更大票数才替换 → 平票取最小偏移（确定性）
            table.sort(offsets)
            local best_offset, best_votes = 0, 0
            for _, off in ipairs(offsets) do
                if votes[off] > best_votes then best_offset, best_votes = off, votes[off] end
            end

            -- 三重门槛 + 触发阈值（min_count 为两源总条数较小者，同参考实现）
            local min_count = math.min(#baseline.entries, #item.entries)
            local diag = {
                url = item.url,
                provider = item.provider,
                drift = best_offset,
                votes = best_votes,
                match_count = match_count,
                applied = false,
            }
            if match_count / min_count < min_match_ratio then
                diag.reason = string.format("文本重合率过低（%d/%d）", match_count, min_count)
            elseif best_votes / min_count < EFFECTIVE_RATIO then
                diag.reason = string.format("有效票率过低（%d/%d）", best_votes, min_count)
            elseif best_votes / match_count < CONSENSUS_RATIO then
                diag.reason = string.format("偏移集中度过低（%d/%d）", best_votes, match_count)
            elseif math.abs(best_offset) < OFFSET_THRESHOLD then
                diag.reason = string.format("偏移 %ds 低于阈值", best_offset)
            else
                diag.applied = true
                diag.reason = string.format("应用平移 %+ds（%d 票）", -best_offset, best_votes)
                result.shifts[item.url] = -best_offset
            end
            result.diag[#result.diag + 1] = diag
        end
    end

    return result
end

return M
