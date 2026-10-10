-- pakku_density 单元测试（自断言，输出 PASS/FAIL 行）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local density = require("modules/pakku_density")

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

local function near(a, b, eps)
    return math.abs(a - b) <= (eps or 1e-6)
end

-- 简易可复现随机数（线性同余，仿 pakku_bench），返回 [0,1)
local function make_rng(seed0)
    local s = seed0
    return function()
        s = (s * 1103515245 + 12345) % 2147483648
        return s / 2147483648
    end
end

-- fixture：默认滚动弹幕 10 个全角字符（dv=√10≈3.1623）、字号 50、duration 15
local TEN = string.rep("哈", 10)
local function ev(start_time, opts)
    opts = opts or {}
    return {
        start_time = start_time,
        end_time = start_time + (opts.duration or 15),
        danmaku = {
            text = opts.text or TEN,
            merge_count = opts.mc or 1,
            font_size = opts.fs or 50,
        },
    }
end
local function wall(n, opts)
    local list = {}
    for i = 1, n do list[i] = ev((i - 1) * 0.01, opts) end -- 同屏密集
    return list
end

-- ---------- effective_length ----------
check("eff 全角 10 字", density.effective_length(TEN) == 10)
check("eff 半角 6 字符=3", density.effective_length("abcdef") == 3)
check("eff 混合=1.5", density.effective_length("哈a") == 1.5)
check("eff 空串/nil=0", density.effective_length("") == 0 and density.effective_length(nil) == 0)

-- ---------- dispval 公式与 clamp ----------
check("dispval 基准字号=√len", near(density.dispval(50, 50, TEN), math.sqrt(10)))
check("dispval 2倍字号=×2^1.5",
    near(density.dispval(100, 50, TEN), math.sqrt(10) * 2 ^ 1.5))
check("dispval 低比 clamp 0.7",
    near(density.dispval(25, 50, TEN), math.sqrt(10) * 0.7 ^ 1.5))
check("dispval 高比 clamp 2.5",
    near(density.dispval(200, 50, TEN), math.sqrt(10) * 2.5 ^ 1.5))

-- ---------- 收缩单调 + 上限（确定性，无随机参与） ----------
-- 40 条同屏 dv=√10，shrink_th=30：第 10 条起 sum>30 触发（10×3.1623=31.62）；
-- 第 40 条 rate=(40×3.1623/30)^0.35≈1.655<√3 未触上限 → 最小 floor(50/1.655)=30
do
    local out, st = density.process(wall(40), { shrink_threshold = 30, drop_threshold = 0 })
    local ok = #out == 40 and st.before == 40 and st.after == 40 and st.dropped == 0
        and st.shrunk == 31
        and out[9].danmaku.font_size == 50 -- 第 9 条 sum=28.46 未触发
        and out[40].danmaku.font_size == 30
    for i = 2, #out do -- 触发后字号非增
        if out[i].danmaku.font_size > out[i - 1].danmaku.font_size then ok = false break end
    end
    check("收缩单调且最小 30（上限 √3 未触）", ok)
end

-- ---------- 权重保护的确定性边界 ----------
-- 前缀 7 条 weight-1（sum=22.14>drop_th=20）：第 8 条 merge_count=11 的
-- hazard=0.107+0.25−(7/8)³/4−(√11−1)/5≈−0.274<0 —— rng 恒返 0（最大压力）也必存活；
-- 对照 weight-1 条 hazard≈0.357>0 —— rng=0 即丢弃
do
    local function prefix8(mc8)
        local list = wall(7)
        list[8] = ev(0.08, { mc = mc8 })
        return list
    end
    local prot, st_p = density.process(prefix8(11),
        { shrink_threshold = 0, drop_threshold = 20, rng = function() return 0 end })
    check("保护边界 mc=11 负 hazard 必存活", #prot == 8 and st_p.dropped == 0)
    local ctrl, st_c = density.process(prefix8(1),
        { shrink_threshold = 0, drop_threshold = 20, rng = function() return 0 end })
    check("对照 mc=1 正 hazard 被丢弃", #ctrl == 7 and st_c.dropped == 1)
end

-- ---------- 加权不等式：mc=10 存活率 > mc=1 ----------
-- 100 条 weight-1 墙 + 5 条 mc=10 交错，drop_th=60（excess 越高两者 hazard 均升，
-- 但 mc=10 恒低 0.648：P(w<10)=100/105 → 0.216 + (√10−1)/5 → 0.432）
do
    local list = {}
    local idx = 0
    for i = 1, 105 do
        if i % 21 == 0 then
            idx = idx + 1
            list[i] = ev((i - 1) * 0.01, { mc = 10 })
        else
            list[i] = ev((i - 1) * 0.01)
        end
    end
    local out, st = density.process(list,
        { shrink_threshold = 0, drop_threshold = 60, rng = make_rng(42) })
    local surv1, surv10 = 0, 0
    for _, e in ipairs(out) do
        if e.danmaku.merge_count == 10 then surv10 = surv10 + 1 else surv1 = surv1 + 1 end
    end
    check("加权不等式 mc10 存活率>mc1 且确有丢弃",
        st.dropped > 0 and (surv10 / 5) > (surv1 / 100))
end

-- ---------- 窗口过期（真实显示区间核心语义） ----------
-- A 滚动(t=0,end=15) + B 固定(t=0,end=5)，shrink_th=4、drop 禁用：
-- B 入窗时 A+B=6.32>4 收缩；C(t=6) 时 B 已出窗但 A 仍在（3.16+3.16=6.32>4）收缩；
-- D(t=22) 时 A/C 均出窗（sum=3.16<4）不收缩
do
    local list = {
        ev(0),                       -- A 滚动 end=15
        ev(0, { duration = 5 }),     -- B 固定 end=5
        ev(6),                       -- C 滚动 end=21
        ev(22),                      -- D 滚动 end=37
    }
    local out, st = density.process(list, { shrink_threshold = 4, drop_threshold = 0 })
    check("窗口过期 A 不缩 B 叠加缩 C 半缩 D 全出窗不缩",
        #out == 4 and st.shrunk == 2
            and out[1].danmaku.font_size == 50
            and out[2].danmaku.font_size < 50
            and out[3].danmaku.font_size < 50
            and out[4].danmaku.font_size == 50)
end

-- ---------- rng 确定性 ----------
do
    local function snapshot(seed)
        local list = wall(60, { mc = 3 })
        local out, st = density.process(list,
            { shrink_threshold = 30, drop_threshold = 40, rng = make_rng(seed) })
        local fs = {}
        for i, e in ipairs(out) do fs[i] = e.danmaku.font_size end
        return st.after, st.dropped, st.shrunk, table.concat(fs, ",")
    end
    local a1, b1, c1, d1 = snapshot(7)
    local a2, b2, c2, d2 = snapshot(7)
    check("同种子两遍结果全等", a1 == a2 and b1 == b2 and c1 == c2 and d1 == d2)
end

-- ---------- 阈值 0 = 阶段禁用（pakku 语义） ----------
do
    local out, st = density.process(wall(40), { shrink_threshold = 0, drop_threshold = 0 })
    local ok = out ~= nil and st.after == st.before and st.dropped == 0 and st.shrunk == 0
    check("双 0 原样直通", ok)
end
do
    local out = density.process(wall(40), { shrink_threshold = 0, drop_threshold = 60 })
    local ok = true
    for _, e in ipairs(out) do
        if e.danmaku.font_size ~= 50 then ok = false break end
    end
    check("shrink=0 字号全不变（丢弃仍可发生）", ok)
end
do
    local _, st = density.process(wall(40), { shrink_threshold = 30, drop_threshold = 0 })
    check("drop=0 丢弃数为 0（收缩仍可发生）", st.dropped == 0 and st.shrunk > 0)
end

-- ---------- 空输入 ----------
do
    local out, st = density.process({}, { shrink_threshold = 50, drop_threshold = 100 })
    check("空输入直通", #out == 0 and st.after == 0)
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
-- os.exit 直杀：mpv 正常 quit 的关机路径在 Windows 控制台代理下偶发挂起（测试环境已知问题）
os.exit(failures > 0 and 1 or 0)
