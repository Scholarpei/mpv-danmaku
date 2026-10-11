-- 弹幕高能时间轴（High-Energy Timeline）：把当前弹幕池按时间分桶统计密度，以**淡淡的
-- 平滑密度曲线**吸附在 uosc 进度条上方显示，峰值小旗标标注高能点，鼠标点击直达。
-- compute / heat_color / format_time / render_ass / uosc_sync / normalize_uosc 为纯函数
-- （无 mp.* 依赖，可单测）；UI 段（overlay / 鼠标绑定 / 观察者）仅运行时调用 mp.*。
--
-- 形态刻意极简：无面板底/表头/页脚/轴刻度/常驻文字——只有低透明度填充曲线、细描边、
-- 峰值小旗标；悬停于曲线区时出现 1px 提示线 + 时间浮签（近峰时显示 ①+时间），点击即
-- 跳转到该时间（16px 内吸附峰值）；当前进度由 uosc 进度条自身指示。视觉风格由
-- options.density_timeline_style 选择（见 STYLES）。
--
-- 吸附与显隐（与 uosc 进度条同步）：uosc 不对外暴露时间轴状态，这里按其源码（5.12）
-- 在本地复刻 Timeline 模型（uosc_sync，坐标为 OSD 实像素）——
--   * 几何吸附：timeline_size/border × state.scale（含 scale_fullscreen 全屏倍率、无边框
--     窗口的仿真边框），曲线基线贴条带顶（含边条）、横向铺满条带左右缘；条带随可见度
--     从常驻 progress 线展开到全高，曲线整体随之升降（从进度条里"长出来"/缩回去）
--   * 可见度同步：鼠标邻近渐变（proximity_in/out，controls 按钮行同计——悬停按钮行时
--     时间轴同样全展开）、timeline/controls 持久化（paused/idle/audio/video/image/
--     windowed/fullscreen）、uosc 菜单打开（curtain）即隐、无时长（直播）即隐
--   * 开合滞回：可见度 ≥0.05 开、<0.02 关；收尾 0.12s 宽限对齐 uosc 离窗的百毫秒淡出
--   * uosc 缺席（未安装/未检出）：回退底部 density_timeline_hover_zone 条带触发 +
--     曲线区保持 + 0.4s 宽限隐藏（旧模型），几何按 uosc 默认值虚拟一条进度条
-- 手动固定显示（总菜单条目 / 可选 conf 键位 / 脚本消息）不受显隐驱动，几何仍跟随
-- （条带收起时曲线落座于常驻 progress 线之上，悬停时随条带展开升起）。
--
-- 数据源：显示瞬间的 COMMENTS 快照（start_time 已含 per-source 延迟与时间轴对齐，
-- merge_count 恢复合并掉的社区刷屏量）。已知限制：density_control=smart 的丢弃与布局
-- 满屏淘汰发生在密度最高处，绝对峰值计数可能被低估——但裁剪对密度单调，argmax 排名
-- （本功能的实际用途：找名场面）不受影响。
--
-- 键盘仅保留 m 切换指标（弹幕量↔视觉密度，会话内粘滞）。点击路由：曲线可见期间注册
-- 非强制 complex MBTN_LEFT 绑定——uosc 在场时未命中其元素的点击会经转发链抵达本绑定
-- （uosc/lib/cursor.lua 的 find_active_keybindings 转发协议），缺席时直接命中；曲线
-- 区外点击不消费。快照语义：每次显示重算，播放中调整延迟/过滤后重新显隐即刷新。

local pakku_density = require("modules/pakku_density")

local M = {}

-- ============ 纯函数段（无 mp.* 依赖，可单测） ============

-- 峰值旗标字形（rank ≤ 10，peaks_n 已 clamp）
local PEAK_GLYPHS = { "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩" }

-- 值→ASS 颜色串（v∈[0,1] 分段线性插值，四舍五入；返回 "&HBBGGRR&" BGR 序）。
-- stops 缺省用 HEAT_STOPS；STYLES 的去饱和档位传入各自的 stops
local function heat_color_stops(v, stops)
    v = tonumber(v) or 0
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    local s0, s1 = stops[1], stops[2]
    for i = 1, #stops - 1 do
        if v <= stops[i + 1].pos then
            s0, s1 = stops[i], stops[i + 1]
            break
        end
    end
    local span = s1.pos - s0.pos
    local t = span > 0 and (v - s0.pos) / span or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local function lerp(a, b) return math.floor(a + (b - a) * t + 0.5) end
    return string.format("&H%02X%02X%02X&", lerp(s0.b, s1.b), lerp(s0.g, s1.g), lerp(s0.r, s1.r))
end

local HEAT_STOPS = {
    { pos = 0.00, r = 0x45, g = 0x68, b = 0x8C },
    { pos = 0.35, r = 0x2F, g = 0xA8, b = 0xC9 },
    { pos = 0.65, r = 0xE8, g = 0xA3, b = 0x3D },
    { pos = 1.00, r = 0xE8, g = 0x56, b = 0x2D },
}

function M.heat_color(v)
    return heat_color_stops(v, HEAT_STOPS)
end

-- 秒 → 紧凑时间标签：<1h "08:42"，否则 "1:02:03"（悬停浮签用）
function M.format_time(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    local h = math.floor(sec / 3600)
    if h > 0 then
        return string.format("%d:%02d:%02d", h, math.floor((sec % 3600) / 60), sec % 60)
    end
    return string.format("%02d:%02d", math.floor(sec / 60), sec % 60)
end

-- 分桶 + 双指标 + 峰值检测（纯函数；确定性：无随机、无 pairs 序依赖）
-- entries: COMMENTS 或同形表（start_time / merge_count / font_size / clean_text），
--          无需预排序（逐条累加，与序无关）
-- opts: bucket(默认10, clamp[5,60]) / peaks_n(默认5, clamp[1,10]) / duration(秒,nil 用
--       弹幕跨度兜底，直播可用) / base_fontsize(dispval 基准,默认50) /
--       min_ratio(峰值最低平滑值/全场最大,默认0.10) / max_buckets(默认600,超限整倍放宽)
-- 返回 { bucket_sec, n, domain, duration_known,
--        metrics = { count   = { buckets={Σmerge_count}, total, mean, smoothed },
--                    density = { buckets={Σdispval},   total, mean, smoothed } },
--        peaks = { count={...}, density={...} } }
-- smoothed = 窗口3平滑序列（曲线渲染与峰值检测同源）；peaks 条目（rank 序，强→弱，
-- 平票早时段优先）：{ bucket=i(1-based), time=(i-1)*bucket_sec, value=平滑值, count=该桶原始弹幕量 }
function M.compute(entries, opts)
    opts = opts or {}
    local bucket = tonumber(opts.bucket) or 10
    if bucket < 5 then bucket = 5 elseif bucket > 60 then bucket = 60 end
    local peaks_n = tonumber(opts.peaks_n) or 5
    if peaks_n < 1 then peaks_n = 1 elseif peaks_n > 10 then peaks_n = 10 end
    local base = tonumber(opts.base_fontsize) or 50
    local min_ratio = tonumber(opts.min_ratio) or 0.10
    local max_buckets = tonumber(opts.max_buckets) or 600

    -- tally 闭包：给定桶宽单遍累加双指标（count=社区弹幕量，density=视觉密度 dispval）。
    -- 逐槽补 0 保持数组稠密（稀疏数组会破坏 # 与 ipairs 语义）
    local function tally(width)
        local cb, db = {}, {}
        local max_start = 0
        for _, e in ipairs(entries or {}) do
            local t = tonumber(e.start_time) or 0
            if t < 0 then t = 0 end -- 防御：管线已钳 0，异常快照兜底
            if t > max_start then max_start = t end
            local idx = math.floor(t / width) + 1
            for i = #cb + 1, idx do cb[i] = 0 db[i] = 0 end
            local mc = tonumber(e.merge_count) or 1
            if mc < 1 then mc = 1 end
            cb[idx] = cb[idx] + mc
            db[idx] = db[idx] + pakku_density.dispval(e.font_size, base, e.clean_text or "")
        end
        return cb, db, max_start
    end

    local duration = tonumber(opts.duration) or 0
    local duration_known = duration > 0
    local cb, db, max_start = tally(bucket)
    if not duration_known then duration = max_start + 1 end

    -- 超长片自适应放宽：桶数超上限按基础桶宽整倍放大（桶边界保持对齐），至多重算一次
    local n_naive = math.ceil(duration / bucket)
    if n_naive > max_buckets then
        bucket = bucket * math.ceil(n_naive / max_buckets)
        cb, db = tally(bucket)
    end

    -- 越界弹幕（多源错位等）扩展域：n 取时长桶数与实际最大桶的较大者
    local n = math.max(math.ceil(duration / bucket), #cb, #db)

    local function mk_metric(arr)
        local total = 0
        for i = 1, #arr do total = total + arr[i] end
        return { buckets = arr, total = total, mean = n > 0 and total / n or 0 }
    end
    local metrics = { count = mk_metric(cb), density = mk_metric(db) }

    -- 平滑（窗口3，边缘收缩分母）：曲线渲染与峰值检测同源——曲线即平滑密度，
    -- 孤立脉冲不尖刺；随 metrics 导出供 render_ass 直接使用
    local function smooth(arr)
        local s = {}
        for i = 1, n do
            local a = i > 1 and (arr[i - 1] or 0) or 0
            local b = arr[i] or 0
            local c = arr[i + 1] or 0
            local w = 1 + (i > 1 and 1 or 0) + (i < n and 1 or 0)
            s[i] = (a + b + c) / w
        end
        return s
    end
    metrics.count.smoothed = smooth(cb)
    metrics.density.smoothed = smooth(db)

    -- 峰值检测：极大平台塌缩到首索引（左侧严格 s[i]>s[i-1]、右侧非严格 s[i]>=s[i+1]，
    -- 边界放宽——首索引语义 = 高能"开始"的桶，亦即平票早时段优先）→ min_ratio 过滤
    -- →（值降、索引升）排序 → 贪心最小间隔（|Δi|×bucket ≥ max(60s, 3桶)）→ 前 peaks_n
    local function find_peaks(arr, s)
        local vmax = 0
        for i = 1, n do
            if s[i] > vmax then vmax = s[i] end
        end
        if vmax <= 0 then return {} end
        local min_sep = math.max(60, 3 * bucket)
        local cands = {}
        for i = 1, n do
            local is_peak = (i == 1 or s[i] > s[i - 1]) and (i == n or s[i] >= s[i + 1])
            if is_peak and s[i] >= min_ratio * vmax then
                -- 平滑会把孤立脉冲抹宽一桶（质量均分进左右邻），平台首索引可能落在
                -- 空桶上；回贴窗口 [i-1, i+1] 内原始值最大的桶（平票取最早），
                -- 保证峰值 time/count 指向真实高能桶
                local best, bv = i, arr[i] or 0
                for j = math.max(1, i - 1), math.min(n, i + 1) do
                    local v = arr[j] or 0
                    if v > bv then best, bv = j, v end
                end
                cands[#cands + 1] = { bucket = best, value = s[i] }
            end
        end
        table.sort(cands, function(a, b)
            if a.value ~= b.value then return a.value > b.value end
            return a.bucket < b.bucket
        end)
        local picked = {}
        for _, c in ipairs(cands) do
            local ok = true
            for _, p in ipairs(picked) do
                if math.abs(p.bucket - c.bucket) * bucket < min_sep then
                    ok = false
                    break
                end
            end
            if ok then
                picked[#picked + 1] = {
                    bucket = c.bucket,
                    time = (c.bucket - 1) * bucket,
                    value = c.value,
                    count = math.floor(arr[c.bucket] or 0),
                }
                if #picked >= peaks_n then break end
            end
        end
        return picked
    end

    return {
        bucket_sec = bucket,
        n = n,
        domain = duration,
        duration_known = duration_known,
        metrics = metrics,
        peaks = {
            count = find_peaks(cb, metrics.count.smoothed),
            density = find_peaks(db, metrics.density.smoothed),
        },
    }
end

-- ============ uosc 时间轴状态复刻（纯函数；uosc 5.12 源码对齐） ============

-- uosc 界面选项缺省（只取几何/邻近/持久化相关的小集合，与 uosc 5.12 上游默认一致）
local UOSC_DEFAULTS = {
    timeline_size = 40, timeline_border = 1,
    progress = "windowed", progress_size = 2,
    proximity_in = 40, proximity_out = 120,
    controls = true, controls_size = 32, controls_margin = 8,
    timeline_persistency = "idle,audio", controls_persistency = "idle,audio",
    scale = 1, scale_fullscreen = 1.3, window_border_size = 1,
    disable_elements = "",
}

-- options/script-opts 里的 uosc 原始键值（值全为字符串）规范化为 uosc_sync 直接可用的
-- 形状；raw 传 nil 返回全默认（uosc 全默认配置 / osc=no 探测命中的兜底形状）。
-- controls 选项串仅识别 'never'（禁用按钮行）；disable_elements 为逗号 id 列表
function M.normalize_uosc(raw)
    raw = raw or {}
    local u = {}
    for k, v in pairs(UOSC_DEFAULTS) do u[k] = raw[k] ~= nil and raw[k] or v end
    for _, k in ipairs({ "timeline_size", "timeline_border", "progress_size", "proximity_in",
        "proximity_out", "controls_size", "controls_margin", "scale", "scale_fullscreen",
        "window_border_size" }) do
        u[k] = tonumber(u[k]) or UOSC_DEFAULTS[k]
    end
    u.controls = tostring(u.controls) ~= "never"
    local disabled = {}
    for id in tostring(u.disable_elements):gmatch("[^,]+") do
        disabled[id:gsub("^%s+", ""):gsub("%s+$", "")] = true
    end
    u.timeline_disabled = disabled.timeline == true
    u.controls_disabled = disabled.controls == true
    return u
end

local function round_px(v) return math.floor(v + 0.5) end

-- 点到矩形邻近距离（uosc get_point_to_rectangle_proximity 复刻：矩形内为 0，
-- 外部为欧氏距离，角部对角线内凹修正）
local function rect_proximity(px, py, r)
    local dx = math.max(r.ax - px, px - r.bx)
    local dy = math.max(r.ay - py, py - r.by)
    return math.sqrt(math.max(0, dx) ^ 2 + math.max(0, dy) ^ 2) + math.min(0, math.max(dx, dy))
end

-- 持久化列表（'idle,audio' 逗号词表）→ 当前是否命中。
-- 词表与条件对齐 uosc Element:is_persistent（paused 的拖拽中豁免不可观测，忽略）
local function persistency_hit(list, env, fom)
    for word in tostring(list or ""):gmatch("[^,]+") do
        local w = word:gsub("^%s+", ""):gsub("%s+$", "")
        if w == "paused" and env.pause then return true
        elseif w == "idle" and env.idle then return true
        elseif w == "audio" and env.has_audio and not env.has_video then return true
        elseif w == "video" and env.has_video then return true
        elseif w == "image" and env.has_image then return true
        elseif w == "windowed" and not fom then return true
        elseif w == "fullscreen" and fom then return true
        end
    end
    return false
end

-- 复刻 uosc Timeline 的可见度与几何。env（collect_env 产出；亦可手工构造）：
--   cursor={x,y}|nil（nil=鼠标不在窗口内，uosc cursor.hidden 语义）、
--   osd_w/osd_h、fullscreen/maximized/border、duration、pause/idle、
--   has_video/has_audio/has_image、hidpi_scale/display_w/display_h（scale=auto 用）、
--   uosc=规范化选项表|nil（nil=uosc 未检出）、menu_open
-- 返回（坐标均为 OSD 实像素）：{ present, visibility(0~1), scale, size, top_border,
--   progress_size, effective_size, ax, bx, ay, by, bar_top, osd_w, osd_h }
--   bar_top = 渲染条带顶（含 border 条）——曲线吸附目标；effective_size 随可见度从
--   progress 线展开到全高（Timeline:get_effective_size 复刻）
-- 未复刻（瞬时/不可观测）：flash-* 闪烁、speed 拖拽强制全高、窗口极小 obstructed
function M.uosc_sync(env)
    env = env or {}
    local present = type(env.uosc) == "table"
    local u = M.normalize_uosc(env.uosc)
    local fom = env.fullscreen == true or env.maximized == true

    -- state.scale 复刻：scale<0 用 hidpi、=0 显示器自适应、>0 字面值；全屏再乘倍率
    local scale_fom = u.scale_fullscreen
    if scale_fom <= 0 then scale_fom = 1 end
    local base
    if u.scale < 0 then
        base = tonumber(env.hidpi_scale) or 1
    elseif u.scale == 0 then
        local dw, dh = tonumber(env.display_w) or 0, tonumber(env.display_h) or 0
        if dw > 0 and dh > 0 then
            base = tonumber(string.format("%.2f", (dw >= dh and dh or dw) / 1080)) or 1
        else
            base = 1
        end
    else
        base = u.scale
    end
    local scale = base * (fom and scale_fom or 1)

    -- Timeline:update_dimensions 几何（wbs=无边框窗口的仿真边框，仅窗口化且
    -- 无原生边框时存在）
    local size = round_px(u.timeline_size * scale)
    local top_border = round_px(u.timeline_border * scale)
    local wbs = 0
    if u.window_border_size > 0 and not fom and env.border ~= true then
        wbs = round_px(u.window_border_size * scale)
    end
    local ow = tonumber(env.osd_w) or 0
    local oh = tonumber(env.osd_h) or 0
    local ax = wbs
    local bx = math.max(ow - wbs, wbs + 1)
    local ay = oh - wbs - size - top_border
    local by = oh - wbs

    -- 可见度：uosc 在场且时间轴可用（有时长、未被禁用、菜单未开）时，
    -- timeline 与 controls 两元素的邻近/持久化取 max（Timeline:get_visibility 复刻；
    -- 悬停时间轴本体时 uosc 把 controls 记为 -1 隐藏，不影响对 timeline 取 max）
    local vis = 0
    local duration_ok = type(env.duration) == "number" and env.duration > 0
    local cursor = type(env.cursor) == "table" and env.cursor or nil
    if present and not u.timeline_disabled and duration_ok and not env.menu_open then
        local function ramp(rect)
            if not cursor then return 0 end
            local raw = rect_proximity(cursor.x, cursor.y, rect)
            local span = u.proximity_out - u.proximity_in
            if span <= 0 then span = 1 end
            return 1 - math.min(math.max(raw - u.proximity_in, 0) / span, 1)
        end
        local vis_tl = persistency_hit(u.timeline_persistency, env, fom) and 1
            or ramp({ ax = ax, ay = ay, bx = bx, by = by })
        local vis_ctl = 0
        if u.controls and not u.controls_disabled then
            local csize = round_px(u.controls_size * scale)
            local cmargin = round_px(u.controls_margin * scale)
            vis_ctl = persistency_hit(u.controls_persistency, env, fom) and 1
                or ramp({
                    ax = ax + cmargin,
                    bx = math.max(bx - cmargin, ax + cmargin + 1),
                    ay = math.max(ay - cmargin - csize, 0),
                    by = math.max(ay - cmargin, 1),
                })
        end
        vis = math.max(vis_tl, vis_ctl)
    end

    -- progress 常驻线仅在对应模式下出现（decide_progress_size 复刻）；
    -- 展开量随可见度（get_effective_size 复刻，speed 拖拽分支忽略）
    local pm = tostring(u.progress)
    local progress_size = (pm == "always" or (pm == "fullscreen" and fom)
        or (pm == "windowed" and not fom)) and u.progress_size or 0
    if progress_size > size then progress_size = size end
    local effective = progress_size + math.ceil((size - progress_size) * vis)

    return {
        present = present, visibility = vis, scale = scale,
        size = size, top_border = top_border, progress_size = progress_size,
        effective_size = effective,
        ax = ax, bx = bx, ay = ay, by = by,
        bar_top = by - effective - top_border,
        osd_w = ow, osd_h = oh,
    }
end

-- ============ 视觉风格（density_timeline_style 选择；均以"不抢戏"为度） ============

-- 两位 hex 透明度按 v∈[0,1] 插值（低值更透，高值稍实）
local function alpha_ramp(lo, hi, v)
    local a = tonumber(lo, 16) + (tonumber(hi, 16) - tonumber(lo, 16)) * (v or 0)
    return string.format("%02X", math.floor(a + 0.5))
end

-- 淡出因子与两位 hex 透明度合成（fade 1=原样，0=全透 FF；>1 钳 1）
local function fade_alpha(hex, fade)
    local a = tonumber(hex, 16)
    if not a then return hex end
    if fade >= 1 then return hex end
    if fade < 0 then fade = 0 end
    return string.format("%02X", math.floor(a + (255 - a) * (1 - fade) + 0.5))
end

local STYLES = {
    -- 融彩：保留热度语义但整体去饱和（钢灰→雾青→沙金→珊瑚），透明度压低
    blend = {
        label = "融彩",
        stops = {
            { pos = 0.00, r = 0x5E, g = 0x70, b = 0x80 },
            { pos = 0.40, r = 0x52, g = 0x8C, b = 0x9A },
            { pos = 0.72, r = 0xC2, g = 0xA4, b = 0x6A },
            { pos = 1.00, r = 0xD1, g = 0x84, b = 0x6C },
        },
        fill_alpha_lo = "E4", fill_alpha_hi = "CC",
        stroke_color = "&HE9EFF2&", stroke_alpha = "B0",
        baseline_alpha = "B0",
        tick_color = "&HAFB6BC&", tick_alpha = "80",
        glyph_color = "B4BCC2",
        hover_color = "&HE6E6E6&", hover_alpha = "C0",
        tooltip_color = "D8DDE2",
    },
    -- 静墨：完全无色相，近白单色 + 透明度编码强度，地震仪轨迹感
    ink = {
        label = "静墨",
        stops = nil,
        fill_color = "&HE9EBEE&",
        fill_alpha_lo = "EA", fill_alpha_hi = "D2",
        stroke_color = "&HE9EBEE&", stroke_alpha = "A8",
        baseline_alpha = "B8",
        tick_color = "&HCFD4D8&", tick_alpha = "88",
        glyph_color = "C6CCD1",
        hover_color = "&HE6E6E6&", hover_alpha = "C0",
        tooltip_color = "D8DDE2",
    },
    -- 月白：单一冷调（淡青），高度即信息，最安静
    moon = {
        label = "月白",
        stops = nil,
        fill_color = "&HE0CFA8&", -- #A8CFE0 淡青的 BGR
        fill_alpha_lo = "E8", fill_alpha_hi = "D0",
        stroke_color = "&HE8F2F6&", stroke_alpha = "A8",
        baseline_alpha = "B8",
        tick_color = "&HD2E2EA&", tick_alpha = "88",
        glyph_color = "C9D9E1",
        hover_color = "&HE6E6E6&", hover_alpha = "C0",
        tooltip_color = "D8E2E8",
    },
}

function M.style_names()
    local names = {}
    for k in pairs(STYLES) do names[#names + 1] = k end
    table.sort(names)
    return names
end

function M.resolve_style(name)
    return STYLES[tostring(name or "")] or STYLES.blend
end

-- 渲染为 ass-events 字符串（纯函数；确定性：同输入同输出）。
-- 形态：淡淡的平滑密度曲线——低透明度填充（相邻桶中心梯形片，色/透明度随热度）+
-- 细描边（非零段各一笔，两端落回基线）+ 峰值小旗标（短刻度线+①字形，无常驻文字）
-- + 一条基线发丝线；悬停时（view.hover_x 给出画布 x）追加 1px 提示线与时间浮签
--（近峰吸附时显示 ①+时间）。入串仅数字/时间/①字形，无用户文本 → 无需 ASS 转义。
-- view: { metric="count"|"density", hover_x=画布px|nil, fade=0~1(整体淡出,默认1) }
-- geom: { width, height, margin, zone_h, bottom_gap }（current_geometry 产出）
-- style: STYLES 条目（draw 经 resolve_style(options.density_timeline_style)）
function M.render_ass(result, view, geom, style)
    style = style or STYLES.blend
    local lines = {}
    local MX = math.floor(geom.margin or 16)
    local GW = math.floor(geom.width or 1920)
    local PW = GW - 2 * MX
    local BASE = math.floor(geom.height or 1080) - math.floor(geom.bottom_gap or 48)
    local CH = math.max(24, math.floor(geom.zone_h or 84) - 26) -- 曲线高度，zone 顶留浮签空间
    local n = math.max(result.n, 1)
    local domain = math.max(result.domain, 1)
    local metric = result.metrics[view.metric] or result.metrics.count
    local peaks = result.peaks[view.metric] or result.peaks.count or {}
    local fade = tonumber(view.fade)
    if fade == nil then fade = 1 end -- 缺省不淡出
    if fade < 0 then fade = 0 elseif fade > 1 then fade = 1 end

    local s = metric.smoothed or {}
    local smax = 0
    for i = 1, n do
        local v = s[i] or 0
        if v > smax then smax = v end
    end

    local function xat(i) return MX + math.floor(((i - 0.5) * PW) / n) end -- 桶中心采样
    local function yat(i) return BASE - math.floor(((s[i] or 0) / smax) * CH) end
    local function fill_color(v01)
        return style.stops and heat_color_stops(v01, style.stops) or style.fill_color
    end

    local function path_event(color, alpha, path)
        lines[#lines + 1] = string.format(
            "{\\an7\\pos(0,0)\\c%s\\alpha&H%s&\\p1}%s{\\p0}", color, alpha, path)
    end

    -- 1 基线发丝线（曲线的"地平线"，紧贴进度条条带顶）
    path_event("&H3A3D42&", fade_alpha(style.baseline_alpha, fade), string.format(
        "m %d %d l %d %d l %d %d l %d %d",
        MX, BASE, MX + PW, BASE, MX + PW, BASE + 1, MX, BASE + 1))

    if smax > 0 then
        -- 2 热度填充：相邻桶中心间的梯形片（右缘 +1px 覆盖抗锯齿缝），热度取两端较高者；
        --    透明度随热度从 lo 渐变到 hi（越低越透）
        local function fill_slice(x0, x1, ia, ib)
            local heat = math.max(s[ia] or 0, s[ib] or 0) / smax
            path_event(fill_color(heat),
                fade_alpha(alpha_ramp(style.fill_alpha_lo, style.fill_alpha_hi, heat), fade),
                string.format("m %d %d l %d %d l %d %d l %d %d",
                    x0, BASE, x0, yat(ia), x1 + 1, yat(ib), x1 + 1, BASE))
        end
        for i = 1, n - 1 do
            if (s[i] or 0) > 0 or (s[i + 1] or 0) > 0 then
                fill_slice(xat(i), xat(i + 1), i, i + 1)
            end
        end
        if (s[1] or 0) > 0 then fill_slice(MX, xat(1), 1, 1) end       -- 左端半桶延伸
        if (s[n] or 0) > 0 then fill_slice(xat(n), MX + PW, n, n) end  -- 右端半桶延伸

        -- 3 曲线描边：非零段各一条 2px 亮带（沿曲线走一笔，向两侧各多带一个零值点落回基线）
        local i = 1
        while i <= n do
            if (s[i] or 0) > 0 then
                local a = i
                repeat
                    i = i + 1
                until i > n or (s[i] or 0) <= 0
                local b = math.min(n, i)
                a = math.max(1, a - 1)
                local top, bot = {}, {}
                for j = a, b do
                    top[#top + 1] = string.format("%s %d %d", j == a and "m" or "l", xat(j), yat(j))
                end
                for j = b, a, -1 do
                    bot[#bot + 1] = string.format("l %d %d", xat(j), yat(j) + 2)
                end
                path_event(style.stroke_color, fade_alpha(style.stroke_alpha, fade),
                    table.concat(top, " ") .. " " .. table.concat(bot, " "))
            else
                i = i + 1
            end
        end
    end

    -- 4 峰值小旗标：2px×8px 短刻度线立于曲线之上 + ①字形（无常驻时间文字）
    for rank, p in ipairs(peaks) do
        local px, py = xat(p.bucket), yat(p.bucket)
        lines[#lines + 1] = string.format(
            "{\\an7\\pos(%d,%d)\\c%s\\alpha&H%s&\\p1}m 0 0 l 2 0 l 2 8 l 0 8{\\p0}",
            px - 1, py - 10, style.tick_color, fade_alpha(style.tick_alpha, fade))
        local lx = math.min(math.max(px, MX + 22), GW - MX - 22)
        lines[#lines + 1] = string.format("{\\an2\\pos(%d,%d)\\fs16\\c&H%s&\\alpha&H%s&}%s",
            lx, py - 12, style.glyph_color, fade_alpha("00", fade),
            PEAK_GLYPHS[rank] or tostring(rank))
    end

    -- 5 悬停提示：1px 竖线 + 时间浮签（近峰 16px 内吸附显示 ①+时间，点击同口径跳转）
    local hx = tonumber(view.hover_x)
    if hx and hx >= MX and hx <= GW - MX then
        hx = math.floor(hx)
        path_event(style.hover_color, fade_alpha(style.hover_alpha, fade), string.format(
            "m %d %d l %d %d l %d %d l %d %d",
            hx, BASE - CH - 24, hx + 1, BASE - CH - 24, hx + 1, BASE + 1, hx, BASE + 1))
        local t = (hx - MX) / PW * domain
        local label = M.format_time(t)
        for rank, p in ipairs(peaks) do
            if math.abs(xat(p.bucket) - hx) <= 16 then
                label = (PEAK_GLYPHS[rank] or tostring(rank)) .. " " .. M.format_time(p.time)
                break
            end
        end
        local tx = math.min(math.max(hx, MX + 34), GW - MX - 34)
        lines[#lines + 1] = string.format("{\\an2\\pos(%d,%d)\\fs20\\c&H%s&\\alpha&H%s&}%s",
            tx, BASE - CH - 28, style.tooltip_color, fade_alpha("00", fade), label)
    end

    return table.concat(lines, "\n")
end

-- ============ UI 段（运行时 mp.*；观察者在模块加载时一次性注册，state==nil 时空转） ============

local state = nil
-- state = { result=compute 快照, metric, hover_x, manual, geometry, sig=绘制签名, last_vis }
local overlay = nil            -- 懒创建，跨开合复用
local default_metric = "count" -- 指标会话内粘滞：close 后再开保持上次选择
local hover_grace_timer = nil

-- 曲线区：高 ~84 画布 px（曲线 58 + 浮签余量），吸附于进度条条带顶之上
local ZONE_H = 84
-- 显隐滞回阈值：可见度 ≥SHOW_EPS 开、<HIDE_EPS 关（中间带保持，防边界抖动）
local SHOW_EPS, HIDE_EPS = 0.05, 0.02
local VIS_Q = 64 -- 可见度量化步进：渐入渐出每 1/64 才重绘一帧
-- OSD 尺寸未知（启动瞬间）的兜底画布几何（px），与旧版常量一致
local FALLBACK_BOTTOM_GAP, FALLBACK_MARGIN = 48, 16

-- 运行时观测缓存（观察者只写这里，collect_env 汇总供纯函数消费）
local rt = {
    mouse = nil, pause = false, fullscreen = false, maximized = false,
    border = false, idle = false, duration = nil,
    track = { video = 0, audio = 0, image = 0 },
    hidpi_scale = nil, display_w = 0, display_h = 0,
    menu_open = false, uosc = nil,
}

-- 解析 uosc 的生效配置。两条通道（实测 mpv-lazy 环境校准）：
--   ① script-opts/uosc.conf 文件直读——mpv 不把文件式键暴露进 options/script-opts
--     属性（隔离实验证实），须用 mp.find_config_file 定位后自行解析（键=value，#注释剥除）；
--   ② options/script-opts 属性里残存的 uosc-* 键（mpv.conf 的 script-opts-append 级，
--     "uosc_" 下划线形式亦兼容）补缺——文件键优先，与 uosc 自身的合并次序一致
-- 一个键都读不到 → nil（uosc 缺席或全默认，后者由 uosc-version 广播 / osc=no 兜底识别）
local function read_uosc_opts()
    local raw = {}
    local ok, path = pcall(function() return mp.find_config_file("script-opts/uosc.conf") end)
    if ok and type(path) == "string" then
        local f = io.open(path, "r")
        if f then
            for line in f:lines() do
                local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
                if key then -- 空值也记录：显式置空（如 persistency=）须盖掉默认，不能回落
                    raw[key] = value:gsub("%s*#.*$", "")
                end
            end
            f:close()
        end
    end
    local so = mp.get_property_native("options/script-opts")
    if type(so) == "table" then
        for k, v in pairs(so) do
            local name = tostring(k):match("^uosc[%-_]([%w_]+)$")
            if name and raw[name] == nil then raw[name] = v end
        end
    end
    if next(raw) == nil then return nil end
    return M.normalize_uosc(raw)
end

-- uosc 在场性判定（三选一命中即认定，选项形状取实测键或全默认）：
-- 读到 uosc.conf / 属性残存 uosc-* 键 / uosc 加载时广播的 uosc-version 消息 / osc 被置 no
local function ensure_uosc()
    if rt.uosc then return end
    rt.uosc = read_uosc_opts()
    if not rt.uosc and mp.get_property_bool("osc", true) == false then
        rt.uosc = M.normalize_uosc(nil)
    end
end

-- 画布：镜像 render.lua 拉伸惯用法并双向补全（宽于 16:9 压高、窄于 16:9 压宽，
-- 全宽曲线在两种极端比例下均完整可见）
local function canvas_geometry()
    local w, h = 1920, 1080
    local ow = mp.get_property_number("osd-width", 0) or 0
    local oh = mp.get_property_number("osd-height", 0) or 0
    if ow > 0 and oh > 0 then
        local ratio = ow / oh
        if ratio > 16 / 9 then
            h = 1920 / ratio
        elseif ratio < 16 / 9 then
            w = 1080 * ratio
        end
    end
    return { width = math.floor(w), height = math.floor(h) }
end

local function collect_env()
    local m = rt.mouse
    local cursor = nil
    if type(m) == "table" and m.hover == true and type(m.x) == "number"
        and type(m.y) == "number" then
        cursor = { x = m.x, y = m.y }
    end
    return {
        cursor = cursor,
        osd_w = mp.get_property_number("osd-width", 0) or 0,
        osd_h = mp.get_property_number("osd-height", 0) or 0,
        fullscreen = rt.fullscreen, maximized = rt.maximized, border = rt.border,
        duration = rt.duration, pause = rt.pause, idle = rt.idle,
        has_video = rt.track.video > 0, has_audio = rt.track.audio > 0,
        has_image = rt.track.image > 0 and rt.track.video == 0 and rt.track.audio == 0,
        hidpi_scale = rt.hidpi_scale, display_w = rt.display_w, display_h = rt.display_h,
        uosc = rt.uosc, menu_open = rt.menu_open,
    }
end

-- 画布几何 + uosc 同步状态：渲染与命中检测的单一事实源。
-- bottom_gap 由条带顶（bar_top）实像素换算到画布——这就是"吸附"；
-- margin 对齐条带左缘（≈窗口仿真边框宽）
local function current_geometry()
    local canvas = canvas_geometry()
    local sync = M.uosc_sync(collect_env())
    local g = {
        width = canvas.width, height = canvas.height,
        margin = FALLBACK_MARGIN, zone_h = ZONE_H,
        bottom_gap = FALLBACK_BOTTOM_GAP,
        sync = sync,
    }
    if sync.osd_w > 0 and sync.osd_h > 0 then
        local sx, sy = canvas.width / sync.osd_w, canvas.height / sync.osd_h
        g.margin = math.max(0, math.floor(sync.ax * sx + 0.5))
        g.bottom_gap = (sync.osd_h - sync.bar_top) * sy
    end
    return g
end

-- 鼠标位置 → (画布 x, 是否在曲线区内)。曲线区 = 条带顶之上 ZONE_H 实像素；
-- 条带本体是 uosc 自己的悬停区（时间浮签/缩略图由 uosc 出），不重复接管
local function mouse_hit(g, pos)
    if type(pos) ~= "table" or pos.hover ~= true or g.sync.osd_w <= 0 or g.sync.osd_h <= 0
        or type(pos.x) ~= "number" or type(pos.y) ~= "number" then
        return nil, false
    end
    local cx = pos.x * g.width / g.sync.osd_w
    local zone_h_real = ZONE_H * g.sync.osd_h / g.height
    return cx, pos.y >= g.sync.bar_top - zone_h_real and pos.y <= g.sync.bar_top
end

local function draw(g)
    if not state then return end
    g = g or state.geometry
    if not g then return end
    if not overlay then overlay = mp.create_osd_overlay("ass-events") end
    -- 手动固定 = 全不透明；uosc 在场时透明度跟随其可见度（条带渐入渐出同步淡出）
    local fade = state.manual and 1 or (g.sync.present and g.sync.visibility or 1)
    if fade < 0 then fade = 0 elseif fade > 1 then fade = 1 end
    local sig = string.format("%d|%d|%d|%d|%d|%s|%s|%s|%d",
        g.sync.effective_size or 0, math.floor(g.bottom_gap or 0), g.margin,
        g.width, g.height, tostring(state.hover_x), state.metric,
        tostring(options.density_timeline_style), math.floor(fade * VIS_Q))
    if sig == state.sig then return end
    state.sig = sig
    overlay.res_x = g.width
    overlay.res_y = g.height
    overlay.z = 2 -- 弹幕双层 z=0/1 之上；show_message 左上锚定与本曲线区无空间冲突
    overlay.data = M.render_ass(state.result,
        { metric = state.metric, hover_x = state.hover_x, fade = fade }, g,
        M.resolve_style(options.density_timeline_style))
    overlay:update()
end

-- 点击跳转：抬起生效（进度条惯例）；窗口坐标 → 时间，16px 内吸附峰值后 seek。
-- 曲线区外不消费（uosc 在场时点击经其转发链抵达，缺席时 input.conf 多为 ignore，无害）。
-- 须先于 open_panel 声明（其 MBTN_LEFT 绑定闭包按词法捕获本局部）
local function on_click(ev)
    if not state or type(ev) ~= "table" or ev.event ~= "up" then return end
    local g = state.geometry or current_geometry()
    local cx, in_zone = mouse_hit(g, mp.get_property_native("mouse-pos"))
    if not in_zone then return end
    local MX = g.margin
    local PW = g.width - 2 * MX
    if cx < MX or cx > g.width - MX then return end
    local t = (cx - MX) / PW * state.result.domain
    for rank, p in ipairs(state.result.peaks[state.metric] or {}) do
        local px = MX + ((p.bucket - 0.5) * PW) / state.result.n
        if math.abs(px - cx) <= 16 then
            t = p.time
            break
        end
    end
    t = math.max(0, math.min(state.result.domain, t))
    mp.commandv("seek", string.format("%.3f", t), "absolute")
end

local function open_panel(manual)
    if state then return end
    if type(COMMENTS) ~= "table" or #COMMENTS == 0 then
        if manual then -- 悬停路径保持安静（反复进出底部不刷 OSD），手动入口才指路
            local key = tostring(options.open_search_danmaku_menu_key or "")
            local hint = key ~= "" and key or "弹幕搜索菜单"
            show_message("暂无弹幕可分析  " .. hint .. " 搜索加载弹幕", 4)
        end
        return
    end
    local result = M.compute(COMMENTS, {
        bucket = tonumber(options.density_timeline_bucket) or 10,
        peaks_n = tonumber(options.density_timeline_peaks) or 5,
        duration = mp.get_property_number("duration", 0),
        base_fontsize = tonumber(options.fontsize) or 50,
    })
    if result.n < 3 then
        if manual then show_message("弹幕时间跨度太短，无法生成高能时间轴", 3) end
        return
    end
    state = {
        result = result, metric = default_metric, hover_x = nil,
        manual = manual or false, geometry = nil, sig = nil, last_vis = 0,
    }
    -- 键盘仅保留 m 切换指标；点击跳转走非强制 complex MBTN_LEFT（uosc 转发链兼容）
    mp.add_forced_key_binding("m", "density_timeline_metric", function() M.cycle_metric() end)
    mp.add_key_binding("MBTN_LEFT", "density_timeline_click", on_click, "complex")
    state.geometry = current_geometry()
    draw(state.geometry)
end

function M.close()
    if hover_grace_timer then
        hover_grace_timer:kill()
        hover_grace_timer = nil
    end
    if overlay then overlay:remove() end
    if state then
        mp.remove_key_binding("density_timeline_metric")
        mp.remove_key_binding("density_timeline_click")
    end
    state = nil
end

function M.cycle_metric()
    if not state then return end
    state.metric = state.metric == "count" and "density" or "count"
    default_metric = state.metric
    state.sig = nil -- 指标不在绘制签名外的输入里，显式失效强制重绘
    draw()
end

-- 手动模式入口（总菜单条目 / 可选键位 / input.conf 自绑）：
-- 关→开（固定显示）；悬停显示中→固定（免鼠标离开即隐）；固定中→关
function density_timeline_toggle()
    if state then
        if state.manual then
            M.close()
        else
            state.manual = true
            state.sig = nil -- fade 从跟随可见度切到 1，强制重绘
            draw()
        end
    else
        open_panel(true)
    end
end

-- 收尾宽限：uosc 在场 0.12s（对齐其离窗百毫秒淡出），缺席回退 0.4s（旧行为）。
-- 回调复核 last_vis——宽限期内状态回升则不关
local function schedule_hide(sec)
    if hover_grace_timer then return end
    hover_grace_timer = mp.add_timeout(sec, function()
        hover_grace_timer = nil
        if state and not state.manual and (state.last_vis or 0) < HIDE_EPS then
            M.close()
        end
    end)
end

-- 核心驱动：鼠标 / 任何相关属性变化 → 重算同步状态 → 开合、几何吸附、悬停推进。
-- uosc 在场按复刻可见度驱动（渐入渐出 + 持久化 + 菜单/时长门控）；缺席回退
-- 底部条带触发模型（旧行为）
local function evaluate()
    local hover_enabled = type(options) == "table" and options.density_timeline_show_on_hover
    if not state and not hover_enabled then return end
    local g = current_geometry()
    local cx, in_zone = mouse_hit(g, rt.mouse)
    local vis = g.sync.visibility

    if not g.sync.present then
        local zone = tonumber(options.density_timeline_hover_zone) or 40
        local m = rt.mouse
        local in_trigger = type(m) == "table" and m.hover == true and g.sync.osd_h > 0
            and type(m.y) == "number" and m.y >= g.sync.osd_h - zone
        if in_trigger or in_zone then
            vis = 1
        elseif state and not state.manual then
            vis = 0
        end
    end

    if state then
        state.geometry = g
        state.last_vis = vis
        if not state.manual and vis < HIDE_EPS then
            schedule_hide(g.sync.present and 0.12 or 0.4)
            return -- 末帧驻留至宽限结束
        end
        if hover_grace_timer then
            hover_grace_timer:kill()
            hover_grace_timer = nil
        end
        state.hover_x = in_zone and cx or nil
        draw(g)
    elseif (g.sync.present and vis >= SHOW_EPS) or (not g.sync.present and vis >= 1) then
        open_panel(false)
    end
end

mp.register_script_message("toggle_density_timeline", density_timeline_toggle)
-- uosc 加载广播：此刻 options/script-opts 必已就绪，重试在场判定
mp.register_script_message("uosc-version", function()
    ensure_uosc()
    evaluate()
end)
mp.add_hook("on_unload", 50, function()
    if state then M.close() end
end)
mp.observe_property("mouse-pos", "native", function(_, v)
    rt.mouse = v
    evaluate()
end)
mp.observe_property("pause", "bool", function(_, v) rt.pause = v or false evaluate() end)
mp.observe_property("fullscreen", "bool", function(_, v) rt.fullscreen = v or false evaluate() end)
mp.observe_property("window-maximized", "bool", function(_, v) rt.maximized = v or false evaluate() end)
mp.observe_property("border", "bool", function(_, v) rt.border = v or false evaluate() end)
mp.observe_property("idle-active", "bool", function(_, v) rt.idle = v or false evaluate() end)
mp.observe_property("duration", "number", function(_, v) rt.duration = v evaluate() end)
mp.observe_property("display-hidpi-scale", "number", function(_, v) rt.hidpi_scale = v evaluate() end)
mp.observe_property("display-width", "number", function(_, v) rt.display_w = v or 0 evaluate() end)
mp.observe_property("display-height", "number", function(_, v) rt.display_h = v or 0 evaluate() end)
-- uosc 菜单打开会拉起 curtain 盖住时间轴（user-data/uosc/menu/type 开=非 nil）
mp.observe_property("user-data/uosc/menu/type", "native", function(_, v)
    rt.menu_open = v ~= nil
    evaluate()
end)
-- 轨道构成（uosc track-list 判定复刻：image/albumart 计图像）→ 持久化条件输入
mp.observe_property("track-list", "native", function(_, v)
    local t = { video = 0, audio = 0, image = 0 }
    for _, track in ipairs(type(v) == "table" and v or {}) do
        if track.type == "video" then
            if track.image or track.albumart then
                t.image = t.image + 1
            else
                t.video = t.video + 1
            end
        elseif track.type == "audio" then
            t.audio = t.audio + 1
        end
    end
    rt.track = t
    evaluate()
end)
mp.observe_property("osd-width", "number", function() evaluate() end)
mp.observe_property("osd-height", "number", function() evaluate() end)

ensure_uosc()

return M
