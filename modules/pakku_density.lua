-- pakku 式智能密度控制引擎（SHRINK / DROP_THRESHOLD 移植）
-- 算法参考并行为复刻自 pakku.js (https://github.com/xmcp/pakku.js, GPLv3, by xmcp)
-- post_combine 密度处理器；本模块为独立实现的纯 Lua 版本，未复制任何 pakku 源码；无 mp.* 依赖以便单元测试
--
-- 流程：滑动窗口视觉密度（dispval）求和 → 超软阈值等比缩小字号 → 超硬阈值按权重概率丢弃
-- （未合并弹幕先死，xN 合并弹幕受 √N 与权重相对排名双重保护）
-- 与 pakku 的差异：
--   1. 过期判定用每条弹幕真实显示区间 [start_time, end_time]（pakku 固定 5s），
--      与 limit_danmaku 的同屏窗口约定一致
--   2. likes 保护项因现有弹幕源均无点赞数据而省略（见 process 内注释钩子）
--   3. dv 按原始 d.text 计算（未经 HTML 实体解码/简繁转换，那发生在布局阶段），
--      含实体的弹幕 dv 略高估，实体极罕见，可接受
--
-- 契约：输入 pre_events 条目含 start_time / end_time / danmaku（.text .merge_count .font_size），
-- 且【同一 duration（end−start）的条目】按 start_time 非降序到达 —— parse.lua 的建表代码保证
-- 该不变量（滚动类 floor(t+0.5) 类内单调，固定类保持原序，两档 duration 恒不同）。
-- 若用户把 scrolltime 配成与 fixtime 相同，同桶内滚动取整与固定原序可能出现 <0.5s 的局部
-- 倒挂，后果仅为密度和短暂高估（≤0.5s），有界优雅降级

local UTF8_PATTERN = '[%z\1-\127\194-\244][\128-\191]*'

-- pakku 常量（pakkujs/core/post_combine.ts）
local DISPVAL_POWER   = 0.35           -- 收缩率幂指数
local SHRINK_MAX_RATE = math.sqrt(3)   -- 1.732…，收缩率上限
local RATIO_MIN       = 0.7            -- dispval 字号比下限（防小字号弹幕密度被低估）
local RATIO_MAX       = 2.5            -- dispval 字号比上限（防超大字号弹幕密度被高估）
local WEIGHT_MAX      = 11             -- 权重截断 clamp(merge_count, 1, 11)
local BASE_HAZARD     = 0.25           -- 丢弃基础死亡概率

-- mp.msg 可选（纯 Lua 测试环境下静默）
local msg = { verbose = function() end, warn = function() end }
pcall(function() msg = require("mp.msg") end)

-- pakku effective_length：unicode 字符数 − ASCII(0x20-0x7E) 数/2（半角记 0.5）。
-- 注意与 utils.get_str_width 不同：不乘字号因子（字号因子由 dispval 的 clamp 项单独承担）
local function effective_length(text)
    if not text or text == "" then return 0 end
    local eff = 0
    for ch in text:gmatch(UTF8_PATTERN) do
        local b = string.byte(ch)
        if #ch == 1 and b >= 0x20 and b <= 0x7E then
            eff = eff + 0.5
        else
            eff = eff + 1
        end
    end
    return eff
end

-- pakku dispval：√有效长度 × clamp(字号/基准字号, 0.7, 2.5)^1.5。
-- pakku 基准 25（B 站像素），本移植基准 = options.fontsize（ASS 单位），
-- 普通弹幕比值为 1 → dispval = √长度，合并放大弹幕按 (字号/基准)^1.5 自然加权
local function dispval(fontsize, base_fontsize, text)
    local base = tonumber(base_fontsize) or 50
    local ratio = (tonumber(fontsize) or base) / base
    if ratio < RATIO_MIN then ratio = RATIO_MIN
    elseif ratio > RATIO_MAX then ratio = RATIO_MAX end
    return math.sqrt(math.max(effective_length(text), 0)) * ratio ^ 1.5
end

-- weight_cdf[w] = 权重严格小于 w 的弹幕占比（pakku 语义：weight_distribution[w-1] 的 w-1
-- 是数组下标，对应 P(weight<w)，保护项为该占比的纯立方 —— 切勿写成 (cdf-1)^3 反向保护弱者）。
-- merge_count=1 恒为 0（先死），全场最高权重至多 −0.25 hazard
local function build_weight_cdf(pre_events)
    local hist, total = {}, 0
    for _, ev in ipairs(pre_events) do
        local w = ev.danmaku.merge_count or 1
        if w < 1 then w = 1 elseif w > WEIGHT_MAX then w = WEIGHT_MAX end
        hist[w] = (hist[w] or 0) + 1
        total = total + 1
    end
    local cdf, cum = {}, 0
    for w = 1, WEIGHT_MAX do
        cdf[w] = total > 0 and (cum / total) or 0
        cum = cum + (hist[w] or 0)
    end
    return cdf
end

-- 智能密度处理主入口。
-- cfg 字段：
--   shrink_threshold 软阈值（<=0 禁用收缩）；drop_threshold 硬阈值（<=0 禁用丢弃）；
--   base_fontsize dispval 基准字号（生产传 options.fontsize）；
--   rng 随机数源，返回 [0,1)，缺省 math.random（parse.lua 已播种；测试注入 LCG 以复现）
-- 逐条处理顺序严格对应 pakku post_combine：
--   (1) 过期扣减 (2) 按收缩前字号算 dv (3) 丢弃判定【累计和不含自身，被丢者不进窗口】
--   (4) 保留者计入窗口 (5) 收缩判定【含自身，队列中的 dv 保持收缩前值】
-- 返回：过滤后的 pre_events 子集（原条目引用，字号原位收缩），stats 统计表
local function process(pre_events, cfg)
    cfg = cfg or {}
    local shrink_th = tonumber(cfg.shrink_threshold) or 0
    local drop_th   = tonumber(cfg.drop_threshold) or 0
    local base      = tonumber(cfg.base_fontsize) or 50
    local rand      = cfg.rng or function() return math.random() end

    local n = #pre_events
    local stats = { before = n, after = n, shrunk = 0, shrunk_by_total = 0, dropped = 0 }
    if n == 0 or (shrink_th <= 0 and drop_th <= 0) then
        return pre_events, stats -- 双阈值禁用：原样直通（pakku 语义）
    end

    local weight_cdf = build_weight_cdf(pre_events)

    -- 按 duration 分桶的过期队列：pre_events 非全局有序（滚动 floor 取整 + 两档时长不同），
    -- 单一 FIFO 队列不正确；同 duration 桶内条目按 start 非降序到达 ⇒ end 亦非降序，
    -- 头指针过期精确且总计 O(n)。桶数恒 <=2（scrolltime/fixtime 各一）。
    -- 条目只推进 head、不置 nil（避免数组空洞破坏 #list 语义）
    local buckets = {} -- duration -> { list = { {end_time=, dv=} ... }, head = 1 }
    local onscreen = 0.0

    local function expire(now)
        for _, b in pairs(buckets) do
            while b.head <= #b.list and now >= b.list[b.head].end_time do
                onscreen = onscreen - b.list[b.head].dv
                b.head = b.head + 1
            end
        end
    end

    local result = {}
    for _, ev in ipairs(pre_events) do
        expire(ev.start_time) -- (1) 过期扣减（与 limit_danmaku 同约定：end_time <= start 即出窗）

        local d = ev.danmaku
        local fs = tonumber(d.font_size) or base -- parse 侧预计算的合并放大字号
        local dv = dispval(fs, base, d.text or "")
        local w = d.merge_count or 1
        if w < 1 then w = 1 elseif w > WEIGHT_MAX then w = WEIGHT_MAX end

        -- (3) 丢弃判定：累计和不含自身；被丢弃者不进窗口、不收缩
        local dropped = false
        if drop_th > 0 and onscreen > drop_th then
            local hazard = (onscreen - drop_th) / drop_th + BASE_HAZARD
                - (weight_cdf[w] or 0) ^ 3 / 4 -- 权重相对排名保护（上限 -0.25）
                - (math.sqrt(w) - 1) / 5       -- √N 合并数保护（mc=10 约 -0.23）
                -- pakku 另有 − √likes/8 项：现有弹幕源均无点赞数据，暂缺；
                -- 未来解析器若提供 likes 字段，在此追加 − math.sqrt(likes) / 8
            if hazard >= 1 or rand() < hazard then
                dropped = true
                stats.dropped = stats.dropped + 1
            end
        end

        if not dropped then
            -- (4) 计入窗口并登记过期项（dv 保持收缩前值，pakku 语义）
            local dur = ev.end_time - ev.start_time
            local b = buckets[dur]
            if not b then
                b = { list = {}, head = 1 }
                buckets[dur] = b
            end
            b.list[#b.list + 1] = { end_time = ev.end_time, dv = dv }
            onscreen = onscreen + dv

            -- (5) 收缩判定（含自身）：字号 /= rate，下限 1（ASS \fs 整数）
            if shrink_th > 0 and onscreen > shrink_th then
                local rate = math.min((onscreen / shrink_th) ^ DISPVAL_POWER, SHRINK_MAX_RATE)
                local new_fs = math.max(1, math.floor(fs / rate))
                if new_fs < fs then
                    stats.shrunk = stats.shrunk + 1
                    stats.shrunk_by_total = stats.shrunk_by_total + (fs - new_fs)
                    d.font_size = new_fs -- 原位收缩，流向下游布局
                end
            end

            result[#result + 1] = ev
        end
    end

    stats.after = #result
    return result, stats
end

return {
    DISPVAL_POWER = DISPVAL_POWER,
    SHRINK_MAX_RATE = SHRINK_MAX_RATE,
    WEIGHT_MAX = WEIGHT_MAX,
    effective_length = effective_length,
    dispval = dispval,
    process = process,
}
