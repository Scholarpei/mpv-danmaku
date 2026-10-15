-- 高能时间轴测试：纯核心（compute 分桶/平滑/峰值检测、heat_color、render_ass 极简曲线
-- 与三种风格、uosc_sync 进度条同步复刻）+ UI 冒烟（uosc 缺席回退悬停显隐 / 提示线 /
-- 点击跳转 / m 切指标；uosc 在场吸附几何 / 渐入渐出 / 持久化 / 菜单即隐）+ 实抓 fixture
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

-- ============ mp.* 打桩（先于 require：模块加载期注册观察者即被捕获） ============

local captured = {
    observers = {}, forced = {}, plain_bindings = {}, removed_forced = {},
    commands = {}, timeouts = {}, overlays = {}, messages = {}, script_messages = {},
    mouse = { x = 0, y = 0, hover = false },
}
-- P 段注入的 uosc script-opts（nil = uosc 缺席回退模式）
local stub_script_opts = nil
mp.observe_property = function(name, kind, fn) captured.observers[name] = fn end
mp.create_osd_overlay = function(kind_)
    local o = { kind = kind_, data = nil, updates = 0, removes = 0 }
    function o:update() self.updates = self.updates + 1 end
    function o:remove() self.removes = self.removes + 1; self.data = nil end
    captured.overlays[#captured.overlays + 1] = o
    return o
end
mp.add_forced_key_binding = function(key, name, fn)
    captured.forced[name] = { key = key, fn = fn }
end
mp.add_key_binding = function(key, name, fn, flags)
    captured.plain_bindings[name] = { key = key, fn = fn, flags = flags }
end
mp.remove_key_binding = function(name)
    captured.removed_forced[#captured.removed_forced + 1] = name
end
mp.commandv = function(...)
    captured.commands[#captured.commands + 1] = { ... }
end
mp.register_script_message = function(name, fn)
    captured.script_messages[name] = fn
end
mp.add_timeout = function(t, fn)
    local tm = { timeout = t, fn = fn, killed = false }
    function tm:kill() self.killed = true end
    function tm:resume() end
    function tm:fire() if not self.killed then self.fn() end end
    captured.timeouts[#captured.timeouts + 1] = tm
    return tm
end
mp.get_property_number = function(name, default)
    if name == "duration" then return 1420 end
    if name == "osd-width" then return 1920 end
    if name == "osd-height" then return 1080 end
    return default
end
mp.get_property_bool = function(name, default)
    if name == "osc" then return true end -- osc=yes → 不走 osc=no 探测，在场性只看 script-opts
    return default
end
mp.get_property_native = function(name)
    if name == "mouse-pos" then return captured.mouse end
    if name == "options/script-opts" then return stub_script_opts end
    return nil
end

show_message = function(text, time)
    captured.messages[#captured.messages + 1] = tostring(text)
end
options = {
    density_timeline_show_on_hover = true,
    density_timeline_hover_zone = 40,
    density_timeline_key = "",
    density_timeline_style = "blend",
    density_timeline_bucket = 10,
    density_timeline_peaks = 5,
    fontsize = 50,
    open_search_danmaku_menu_key = "Ctrl+d",
}

local dt = require("modules/density_timeline")

-- ============ 构造器 ============

local function mk_entry(t, opts)
    opts = opts or {}
    return {
        start_time = t,
        merge_count = opts.mc or 1,
        font_size = opts.fs or 50,
        clean_text = opts.text or "哈",
    }
end

local function burst(list, t0, n, mc)
    for i = 0, n - 1 do list[#list + 1] = mk_entry(t0 + i, { mc = mc }) end
end

-- 确定性序列化（A9 对比两次 compute 输出用）
local function dump(v)
    if type(v) ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = k .. "=" .. dump(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
end

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

-- ============ A. compute ============

do -- A1 桶边界：0 / 9.99 入桶1，10 入桶2
    local r = dt.compute({ mk_entry(0), mk_entry(9.99), mk_entry(10) }, { duration = 30 })
    check("A1 桶边界", r.metrics.count.buckets[1] == 2 and r.metrics.count.buckets[2] == 1)
end

do -- A2 merge_count 加权恢复社区刷屏量
    local r = dt.compute({ mk_entry(5, { mc = 5 }) }, { duration = 30 })
    check("A2 merge_count 加权", r.metrics.count.buckets[1] == 5)
end

do -- A3 负 start_time 防御性入桶1
    local r = dt.compute({ mk_entry(-7) }, { duration = 30 })
    check("A3 负时间入桶1", r.metrics.count.buckets[1] == 1)
end

do -- A4 空 entries：零总量、双指标均无峰值
    local r = dt.compute({}, { duration = 30 })
    check("A4 空输入", r.metrics.count.total == 0 and #r.peaks.count == 0 and #r.peaks.density == 0)
end

do -- A5 duration 推桶数（1420s → 142 桶，末桶可容纳 1415s 弹幕）
    local r = dt.compute({ mk_entry(1415) }, { duration = 1420 })
    check("A5 duration 推桶数", r.n == 142 and r.metrics.count.buckets[142] == 1)
end

do -- A6 无 duration：弹幕跨度兜底（max_start 99.5 → domain 100.5 → 11 桶），标直播
    local r = dt.compute({ mk_entry(99.5) }, {})
    check("A6 跨度兜底", r.n == 11 and r.duration_known == false)
end

do -- A7 超长片自适应放宽：7200s → bucket×2=20、n=360（≤600）
    local r = dt.compute({ mk_entry(7199) }, { duration = 7200 })
    check("A7 自适应放宽", r.bucket_sec == 20 and r.n == 360
        and r.metrics.count.buckets[360] == 1)
end

do -- A8 双指标：同弹幕量、不同字号 → 视觉密度总和不同；平滑序列随指标导出
    local r = dt.compute({ mk_entry(0, { fs = 25 }), mk_entry(0, { fs = 100 }) },
        { duration = 30, base_fontsize = 50 })
    check("A8 双指标分流", r.metrics.count.total == 2
        and r.metrics.density.total ~= r.metrics.count.total
        and #r.metrics.count.smoothed == r.n)
end

do -- A9 确定性：同输入两次 compute 输出深度一致
    local fixture = {}
    for i = 1, 200 do fixture[i] = mk_entry((i * 37) % 1300, { mc = i % 7 }) end
    check("A9 确定性", dump(dt.compute(fixture, { duration = 1400 }))
        == dump(dt.compute(fixture, { duration = 1400 })))
end

-- ============ B. 峰值检测 ============

do -- B1 单脉冲：恰一峰、指向该桶
    local r = dt.compute({ mk_entry(5) }, { duration = 300 })
    local p = r.peaks.count
    check("B1 单脉冲", #p == 1 and p[1].bucket == 1 and p[1].count == 1)
end

do -- B2 平台塌缩到首索引：等值平台只出一个候选
    local list = {}
    burst(list, 0, 3, 1) -- 桶 1-3 等值
    local r = dt.compute(list, { duration = 300 })
    check("B2 平台塌缩首索引", #r.peaks.count == 1 and r.peaks.count[1].bucket == 1)
end

do -- B3 min_ratio 过滤：远弱于全局最大的小鼓包不标峰
    local list = { mk_entry(5), mk_entry(505, { mc = 100 }) }
    local r = dt.compute(list, { duration = 600 })
    local p = r.peaks.count
    check("B3 min_ratio 过滤", #p == 1 and p[1].bucket == 51)
end

do -- B4 最小间隔：相邻 2 桶的双峰只留强者（平滑等值时平台塌缩为一）
    local list = { mk_entry(100, { mc = 50 }), mk_entry(115, { mc = 40 }) }
    local r = dt.compute(list, { duration = 600 })
    check("B4 最小间隔", #r.peaks.count == 1 and r.peaks.count[1].bucket == 11)
end

do -- B5 top-N 截断 + rank 序（强→弱）
    local list = {}
    local mcs = { 7, 6, 5, 4, 3, 2, 1 }
    for i, mc in ipairs(mcs) do list[#list + 1] = mk_entry(100 + (i - 1) * 200, { mc = mc }) end
    local r = dt.compute(list, { duration = 1500, peaks_n = 3 })
    local p = r.peaks.count
    check("B5 top-N 与 rank 序", #p == 3 and p[1].bucket == 11 and p[2].bucket == 31
        and p[3].bucket == 51)
end

do -- B6 平票早时段优先
    local list = { mk_entry(100, { mc = 10 }), mk_entry(500, { mc = 10 }) }
    local r = dt.compute(list, { duration = 600 })
    check("B6 平票早时段优先", r.peaks.count[1].bucket == 11 and r.peaks.count[2].bucket == 51)
end

do -- B7 峰值时间=桶起点、count=该桶原始弹幕量
    local r = dt.compute({ mk_entry(100, { mc = 42 }) }, { duration = 300 })
    local p = r.peaks.count[1]
    check("B7 桶起点时间与原始计数", p.time == (p.bucket - 1) * 10 and p.count == 42)
end

-- ============ C. render_ass / heat_color / styles ============

-- 固定渲染 fixture：5 个非零桶（60/120/3/4/2），双峰（桶31 强、桶11 次强）
local c_entries = {}
burst(c_entries, 100, 6, 10) -- 桶 11：60
burst(c_entries, 300, 6, 20) -- 桶 31：120
burst(c_entries, 500, 3, 1)  -- 桶 51：3
burst(c_entries, 700, 4, 1)  -- 桶 71：4
burst(c_entries, 1000, 2, 1) -- 桶 101：2
local c_result = dt.compute(c_entries, { duration = 1420 })
local c_geom = { width = 1920, height = 1080, margin = 16, zone_h = 84, bottom_gap = 48 }
local c_style = dt.resolve_style("blend")
local function c_render(view, style)
    return dt.render_ass(c_result, view or { metric = "count" }, c_geom,
        style or c_style)
end

do -- C1 \p1 事件数 = 基线 + 热度填充片 + 描边段 + 峰值刻度线（期望值按同口径复算）
    local s = c_result.metrics.count.smoothed
    local n = c_result.n
    local fills = 0
    for i = 1, n - 1 do
        if (s[i] or 0) > 0 or (s[i + 1] or 0) > 0 then fills = fills + 1 end
    end
    if (s[1] or 0) > 0 then fills = fills + 1 end
    if (s[n] or 0) > 0 then fills = fills + 1 end
    local runs, inrun = 0, false
    for i = 1, n do
        local v = (s[i] or 0) > 0
        if v and not inrun then runs = runs + 1 end
        inrun = v
    end
    local _, cnt = c_render():gsub("\\p1", "")
    check("C1 绘制事件数", cnt == 1 + fills + runs + #c_result.peaks.count,
        cnt .. "/" .. (1 + fills + runs + #c_result.peaks.count))
end

do -- C2 峰值旗标仅字形无常驻时间文字
    local data = c_render()
    check("C2 峰值旗标", data:find("①", 1, true) and data:find("②", 1, true)
        and not data:find("① 05:00", 1, true) and not data:find("01:40", 1, true))
end

do -- C3 悬停：提示线 + 时间浮签；近峰 16px 内显示 ①+时间
    local p1 = c_result.peaks.count[1]
    local px = 16 + math.floor(((p1.bucket - 0.5) * (1920 - 32)) / c_result.n)
    local data = c_render({ metric = "count", hover_x = px })
    local far = c_render({ metric = "count", hover_x = px + 300 })
    local far_t = string.format("%02d:%02d", math.floor((px + 300 - 16) / (1920 - 32) * 1420 / 60),
        math.floor((px + 300 - 16) / (1920 - 32) * 1420) % 60)
    check("C3 悬停浮签", data:find("① 05:00", 1, true) and far:find(far_t, 1, true))
end

do -- C3b fade：0.5 时所有透明度位向 FF 收敛（淡出），文字事件带 alpha；1 时与无 fade 一致
    local full = c_render()
    local faded = c_render({ metric = "count", fade = 0.5 })
    local function alphas(s)
        local t = {}
        for a in s:gmatch("\\alpha&H(%x%x)&") do t[#t + 1] = a end
        return t
    end
    local af, aa = alphas(faded), alphas(full)
    local converged = #af > 0 and #af == #aa
    for i = 1, math.min(#af, #aa) do
        if tonumber(af[i], 16) <= tonumber(aa[i], 16) then converged = false break end
    end
    check("C3b fade 收敛与恒等", converged
        and c_render({ metric = "count", fade = 1 }) == full)
end

do -- C4 极简形态：无面板底/表头/页脚/轴刻度等任何 chrome
    local data = c_render()
    check("C4 极简形态", not data:find("弹幕高能时间轴", 1, true)
        and not data:find("总弹幕", 1, true)
        and not data:find("Esc 关闭", 1, true)
        and not data:find("Enter", 1, true))
end

do -- C5 确定性：同输入字节级一致（含悬停态）
    check("C5 渲染确定性", c_render() == c_render()
        and c_render({ metric = "count", hover_x = 400 }) == c_render({ metric = "count", hover_x = 400 }))
end

do -- C6 全零指标（空文本 → dispval=0）：仅剩基线发丝线，无旗标
    local r0 = dt.compute({ mk_entry(0, { text = "" }), mk_entry(10, { text = "" }),
        mk_entry(20, { text = "" }) }, { duration = 300 })
    local data = dt.render_ass(r0, { metric = "density" }, c_geom, c_style)
    local _, cnt = data:gsub("\\p1", "")
    check("C6 全零指标渲染", cnt == 1 and not data:find("①", 1, true), cnt)
end

do -- C7 无轴刻度标签
    local _, a6 = c_render():gsub("\\an6", "")
    local _, a4 = c_render():gsub("\\an4", "")
    check("C7 无轴刻度", a6 == 0 and a4 == 0, a6 .. "/" .. a4)
end

do -- C8 热度端点与插值（BGR 序；插值点远离取整边界）
    check("C8 heat_color", dt.heat_color(0) == "&H8C6845&"
        and dt.heat_color(1) == "&H2D56E8&"
        and dt.heat_color(0.2) == "&HAF8D38&",
        dt.heat_color(0) .. "/" .. dt.heat_color(0.2) .. "/" .. dt.heat_color(1))
end

do -- C9 三种风格均可渲染且彼此不同；非法风格名回落 blend
    local blend = c_render(nil, dt.resolve_style("blend"))
    local ink = c_render(nil, dt.resolve_style("ink"))
    local moon = c_render(nil, dt.resolve_style("moon"))
    check("C9 风格集", blend and ink and moon and blend ~= ink and ink ~= moon
        and c_render(nil, dt.resolve_style("不存在")) == blend)
end

-- ============ F. uosc_sync / normalize_uosc（进度条同步复刻，纯函数） ============

-- 标准环境：1920x1080 窗口化、无边框（wbs 生效）、uosc 全默认、时长 1420。
-- pairs 合并——显式传 nil 的场景（F6 直播/uosc 缺席）须手工构造 env
local function fenv(extra)
    local e = {
        osd_w = 1920, osd_h = 1080,
        border = false, duration = 1420, uosc = {},
    }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end

do -- F1 窗口化几何：size 40 + border 1 + 仿真边框 1；无鼠标 → 塌缩到 2px progress 线
    local s = dt.uosc_sync(fenv())
    check("F1 窗口化几何", s.present and s.size == 40 and s.top_border == 1
        and s.ax == 1 and s.bx == 1919 and s.ay == 1038 and s.by == 1079
        and s.progress_size == 2 and s.effective_size == 2 and s.bar_top == 1076
        and s.visibility == 0)
end

do -- F2 全屏：scale 1.3 → size 52、wbs 0；progress=windowed 全屏不驻留 → effective 0
    local s = dt.uosc_sync(fenv({ fullscreen = true }))
    check("F2 全屏几何", s.size == 52 and s.top_border == 1
        and s.ax == 0 and s.bx == 1920 and s.ay == 1027 and s.by == 1080
        and s.progress_size == 0 and s.effective_size == 0 and s.bar_top == 1079)
end

do -- F3 邻近渐变（tl 全高条带 + controls 按钮行取 max；in 40 / out 120）：
    --  y=1038 在条带上 → 1；y=980 距按钮行 18 → 1；y=950 → 0.9；y=900 → 0.275；y=860 → 0
    local function vis_at(y)
        return dt.uosc_sync(fenv({ cursor = { x = 960, y = y } })).visibility
    end
    check("F3 邻近渐变", vis_at(1038) == 1 and vis_at(980) == 1
        and near(vis_at(950), 0.9) and near(vis_at(900), 0.275) and vis_at(860) == 0,
        vis_at(950) .. "/" .. vis_at(900))
end

do -- F4 展开量：vis 1 → 全高 40；progress=always 全屏也保 2px 底线
    local s = dt.uosc_sync(fenv({ cursor = { x = 960, y = 1050 } }))
    local always = dt.uosc_sync(fenv({ fullscreen = true, progress_always = nil,
        uosc = { progress = "always" } }))
    check("F4 展开量", s.visibility == 1 and s.effective_size == 40 and s.bar_top == 1038
        and always.progress_size == 2 and always.effective_size == 2)
end

do -- F5 持久化：paused/idle 命中即全显（无需鼠标）
    local paused = dt.uosc_sync(fenv({ pause = true, uosc = { timeline_persistency = "paused" } }))
    local idle = dt.uosc_sync(fenv({ idle = true, uosc = { timeline_persistency = "idle,audio" } }))
    local off = dt.uosc_sync(fenv({ pause = true, uosc = { timeline_persistency = "" } }))
    check("F5 持久化", paused.visibility == 1 and idle.visibility == 1 and off.visibility == 0)
end

do -- F6 门控：无时长（直播）/菜单打开/时间轴被禁用/uosc 缺席 → 0。
    -- live/absent 的 duration/uosc 须缺键（直播/缺席），不能经 fenv 传 nil
    local cur = { x = 960, y = 1050 }
    local live = dt.uosc_sync({ osd_w = 1920, osd_h = 1080, border = false, uosc = {}, cursor = cur })
    local menu = dt.uosc_sync(fenv({ cursor = cur, menu_open = true }))
    local dis = dt.uosc_sync(fenv({ cursor = cur, uosc = { disable_elements = "timeline" } }))
    local absent = dt.uosc_sync({ osd_w = 1920, osd_h = 1080, border = false, duration = 1420,
        cursor = cur })
    check("F6 门控", live.visibility == 0 and menu.visibility == 0
        and dis.visibility == 0 and absent.visibility == 0 and absent.present == false)
end

do -- F7 scale=0 显示器自适应：4K 显示器 → ×2（size 80 / wbs 2 / border 1×2 取整 2）
    local s = dt.uosc_sync(fenv({ uosc = { scale = 0 },
        display_w = 3840, display_h = 2160 }))
    check("F7 auto scale", s.size == 80 and s.ax == 2 and s.ay == 996 and s.by == 1078,
        s.size .. "/" .. s.ax .. "/" .. s.ay)
end

do -- F8 normalize_uosc：字符串规范化 / controls=never / disable_elements 列表 / nil 全默认
    local u = dt.normalize_uosc({ timeline_size = "30", controls = "never",
        disable_elements = "timeline, volume" })
    local d = dt.normalize_uosc(nil)
    check("F8 normalize", u.timeline_size == 30 and u.controls == false
        and u.timeline_disabled == true
        and d.timeline_size == 40 and d.controls == true and d.timeline_disabled == false)
end

-- ============ D. UI 冒烟（uosc 缺席回退模式；monkey-patch 捕获） ============

-- 回退模式几何（uosc 默认值虚拟进度条，border=false → wbs=1）：
-- bar_top=1076、曲线区 y∈[992,1076]、触发条带 y≥1040、画布 margin=1
local D_MARGIN = 1

local function comments_fixture()
    local list = {}
    burst(list, 200, 20, 5) -- 桶 21：100 → rank1（t=200）
    burst(list, 800, 10, 1) -- 桶 81：10 → rank2（t=800）
    for t = 0, 1400, 100 do list[#list + 1] = mk_entry(t) end -- 底噪
    return list
end

local overlay -- 模块懒创建后复用的同一 overlay 对象

do -- D1 无弹幕：手动入口指引消息、不开面板
    COMMENTS = nil
    density_timeline_toggle()
    check("D1 空态指引", #captured.messages == 1
        and captured.messages[1]:find("暂无弹幕可分析", 1, true)
        and captured.messages[1]:find("Ctrl+d", 1, true)
        and #captured.overlays == 0,
        #captured.messages .. "msgs/" .. #captured.overlays .. "ov/")
end

do -- D2 手动打开：仅 m 强制键 + 非强制 complex MBTN_LEFT；曲线旗标就位、无面板 chrome
    COMMENTS = comments_fixture()
    density_timeline_toggle()
    overlay = captured.overlays[1]
    local click = captured.plain_bindings["density_timeline_click"]
    check("D2 打开与绑定", captured.forced["density_timeline_metric"] ~= nil
        and click and click.key == "MBTN_LEFT" and click.flags == "complex"
        and overlay and overlay.data and overlay.data:find("①", 1, true)
        and not overlay.data:find("弹幕高能时间轴", 1, true))
end

do -- D3 点击峰值旗标 → 吸附跳转峰值时间；点击曲线区外不消费
    local p1x = D_MARGIN + ((21 - 0.5) * (1920 - 2 * D_MARGIN)) / 142
    local click = captured.plain_bindings["density_timeline_click"].fn
    local cmds_before = #captured.commands
    captured.mouse = { x = math.floor(p1x), y = 1000, hover = true }
    click({ event = "up" })
    local seek1 = captured.commands[#captured.commands]
    captured.mouse = { x = 960, y = 500, hover = true } -- 曲线区之上：不消费
    click({ event = "up" })
    captured.mouse = { x = math.floor(p1x), y = 1000, hover = true }
    click({ event = "down" }) -- 仅抬起生效
    check("D3 点击跳转吸附", seek1 and #captured.commands - cmds_before == 1
        and seek1[1] == "seek" and seek1[3] == "absolute" and seek1[2] == "200.000"
        and overlay.data ~= nil, tostring(seek1 and seek1[2]))
end

do -- D4 点击任意位置 → 该处时间（非吸附区精确换算）
    local click = captured.plain_bindings["density_timeline_click"].fn
    captured.mouse = { x = 500, y = 1000, hover = true }
    click({ event = "up" })
    local cmd = captured.commands[#captured.commands]
    local expect = (500 - D_MARGIN) / (1920 - 2 * D_MARGIN) * 1420
    check("D4 点击换算", cmd and cmd[1] == "seek"
        and math.abs(tonumber(cmd[2]) - expect) < 0.01,
        tostring(cmd and cmd[2]) .. "/" .. string.format("%.3f", expect))
end

do -- D4b final offset refreshes the visible curve and its peak seek target.
    local saved_mouse = captured.mouse
    local offset = require('modules/global_delay')
    for _,event in ipairs(COMMENTS) do event.end_time = event.start_time + 5 end
    offset.publish(COMMENTS)
    local updates = overlay.updates
    offset.adjust(-100)
    local click = captured.plain_bindings['density_timeline_click'].fn
    captured.mouse = {x=math.floor(1 + 10.5 * 1918 / 142), y=1000, hover=true}
    click({event='up'})
    local seek = captured.commands[#captured.commands]
    check('D4b final offset refreshes visible peaks and seek',
        overlay.updates > updates and seek and seek[1]=='seek' and seek[2]=='100.000', tostring(seek and seek[2])..'/'..tostring(overlay.updates)..'/'..tostring(updates))
    offset.set(0)
    captured.mouse = saved_mouse
end

do -- D5 m 切指标：曲线口径切换且会话内粘滞（重开后保持）
    local before = overlay.data
    captured.forced["density_timeline_metric"].fn()
    local after = overlay.data
    dt.close()
    density_timeline_toggle()
    local reopened = overlay.data
    check("D5 m 切指标粘滞", before ~= after and reopened == after)
    dt.close()
end

do -- D6 close 幂等且解除全部绑定
    density_timeline_toggle()
    local removed_before = #captured.removed_forced
    dt.close()
    dt.close()
    check("D6 close 幂等", #captured.removed_forced - removed_before == 2) -- metric + click
end

do -- D7 回退悬停显隐 + 提示线：入底部触发区显示 → 曲线区内保持并出浮签 → 离区宽限后
    --    隐藏 → 再入重现；手动模式免疫（排宽限后仍在）
    local mouse = captured.observers["mouse-pos"]
    check("D7 悬停观察者就位", type(mouse) == "function")
    mouse(nil, { x = 960, y = 1060, hover = true }) -- 进入底部触发区（zone=40 → y≥1040）
    local opened = overlay.data ~= nil and overlay.data:find("①", 1, true) ~= nil
    mouse(nil, { x = 500, y = 1050, hover = true }) -- 曲线区内（y∈[992,1076]）
    local label1 = dt.format_time((500 - D_MARGIN) / (1920 - 2 * D_MARGIN) * 1420)
    local tipped = overlay.data:find(label1, 1, true) ~= nil
    mouse(nil, { x = 960, y = 1050, hover = true })
    local label2 = dt.format_time((960 - D_MARGIN) / (1920 - 2 * D_MARGIN) * 1420)
    local tipped2 = overlay.data:find(label2, 1, true) ~= nil -- 浮签随位置移动
    local kept = overlay.data ~= nil and #captured.timeouts == 0
    mouse(nil, { x = 960, y = 900, hover = true }) -- 离开：排 0.4s 宽限
    local grace = captured.timeouts[#captured.timeouts]
    local removes_before = overlay.removes
    grace:fire()
    local hidden = overlay.removes > removes_before
    mouse(nil, { x = 960, y = 1060, hover = true }) -- 再入重现
    local reopened = overlay.data ~= nil
    density_timeline_toggle() -- 悬停显示中经入口固定（pin）
    local removed_manual = #captured.removed_forced
    mouse(nil, { x = 960, y = 900, hover = true }) -- 离区：手动不排宽限、不关
    local timers_manual = #captured.timeouts
    local immune = overlay.data ~= nil and #captured.removed_forced == removed_manual
    dt.close()
    local function bit(v) return v and "1" or "0" end
    check("D7 回退悬停显隐与手动免疫",
        opened and tipped and tipped2 and kept and hidden and reopened and immune
        and timers_manual == #captured.timeouts,
        bit(opened) .. bit(tipped) .. bit(tipped2) .. bit(kept) .. bit(hidden)
        .. bit(reopened) .. bit(immune))
end

-- ============ P. UI 冒烟（uosc 在场：重载模块注入 script-opts） ============

-- 注入用户形配置（persistency=paused 用于 P4），重载模块使其以 uosc 在场模式初始化
stub_script_opts = {
    ["uosc-timeline_size"] = "40",
    ["uosc-timeline_persistency"] = "paused",
    ["uosc-controls_persistency"] = "",
}
package.loaded["modules/density_timeline"] = nil
local dt2 = require("modules/density_timeline")
local mouse2 = captured.observers["mouse-pos"]
captured.observers["duration"](nil, 1420) -- rt.duration 就位（否则按直播门控，可见度恒 0）

-- 在场几何（与 F1 同）：bar_top(全显)=1038、画布 margin=1、BASE=1039（吸附条带顶）
do -- P1 远场不开：远离进度条与按钮行（y=860 距两矩形均 >120）
    mouse2(nil, { x = 960, y = 860, hover = true })
    check("P1 远场不开", #captured.overlays == 1, #captured.overlays)
end

do -- P2 悬停进度条：开启且基线吸附条带顶（BASE=1038=条带顶含边条，而非旧版 48px）
    mouse2(nil, { x = 960, y = 1050, hover = true })
    local ov = captured.overlays[2]
    check("P2 吸附几何", ov and ov.data and ov.data:find("①", 1, true)
        and ov.data:find("m 1 1038 l 1919 1038", 1, true) ~= nil,
        ov and ov.data and ov.data:sub(1, 120) or "no overlay")
end

do -- P3 曲线区悬停出浮签；点击换算与回退模式同口径（margin=1）
    mouse2(nil, { x = 500, y = 1030, hover = true }) -- 曲线区 y∈[954,1038]
    local ov = captured.overlays[2]
    local label = dt2.format_time((500 - 1) / (1920 - 2) * 1420)
    local click = captured.plain_bindings["density_timeline_click"].fn
    click({ event = "up" })
    local cmd = captured.commands[#captured.commands]
    check("P3 曲线区浮签与点击", ov.data:find(label, 1, true) ~= nil
        and cmd and cmd[1] == "seek"
        and math.abs(tonumber(cmd[2]) - (500 - 1) / (1920 - 2) * 1420) < 0.01)
end

do -- P4 渐入带：中距离（vis=0.9）保持显示且整体淡出（alpha 收敛）；远场 0.12s 收尾隐藏
    local ov = captured.overlays[2]
    mouse2(nil, { x = 960, y = 950, hover = true }) -- vis=0.9（见 F3）
    local faded = ov.data:find("\\alpha&HB8&", 1, true) ~= nil -- 基线 B0×fade0.9 → B8
    mouse2(nil, { x = 960, y = 860, hover = true }) -- 远场 → 0.12s 宽限
    local grace = captured.timeouts[#captured.timeouts]
    local removes_before = ov.removes
    check("P4 渐入淡出与收尾", faded and grace ~= nil and math.abs(grace.timeout - 0.12) < 1e-6,
        tostring(faded) .. "/" .. tostring(grace and grace.timeout))
    grace:fire()
    check("P4b 宽限后关闭", ov.removes > removes_before)
end

do -- P5 暂停持久化（timeline_persistency=paused）：无鼠标也全显；恢复播放即隐
    captured.observers["pause"](nil, true)
    local ov = captured.overlays[2]
    local shown = ov and ov.data ~= nil
    captured.observers["pause"](nil, false)
    local grace = captured.timeouts[#captured.timeouts]
    local removes_before = ov.removes
    if grace then grace:fire() end
    check("P5 暂停持久化", shown and ov.removes > removes_before)
end

do -- P6 uosc 菜单打开（curtain）即隐；菜单关闭后悬停恢复
    mouse2(nil, { x = 960, y = 1050, hover = true })
    local ov = captured.overlays[2]
    local opened = ov.data ~= nil
    captured.observers["user-data/uosc/menu/type"](nil, "main")
    local grace = captured.timeouts[#captured.timeouts]
    local removes_before = ov.removes
    if grace then grace:fire() end
    local hidden = ov.removes > removes_before
    captured.observers["user-data/uosc/menu/type"](nil, nil)
    mouse2(nil, { x = 960, y = 1050, hover = true })
    check("P6 菜单即隐与恢复", opened and hidden and ov.data ~= nil)
end

stub_script_opts = nil

-- ============ E. 实抓 fixture（弹弹play 同集真实弹幕） ============

do
    local utils = require("mp.utils")
    local f = io.open(root .. "/tests/fixtures/seihantai_ddp_e06.json", "r")
    local d = f and utils.parse_json(f:read("*a"))
    if f then f:close() end
    if not d then
        check("E fixture 可读", false, "seihantai_ddp_e06.json 缺失")
    else
        -- 镜像 timeline_align_real_test 的 load_ddp（p = time,type,color,uid CSV + m 文本）
        local entries = {}
        for _, cm in ipairs(d.comments or {}) do
            local it = (cm.p or ""):gmatch("([^,]+)")
            entries[#entries + 1] = {
                start_time = tonumber(it()) or 0,
                merge_count = 1, font_size = 25, clean_text = cm.m or "",
            }
        end
        local r = dt.compute(entries, { bucket = 10, peaks_n = 5 })

        local sum = 0
        for i = 1, #r.metrics.count.buckets do sum = sum + r.metrics.count.buckets[i] end
        check("E1 实抓条数守恒", #entries == 5249 and sum == 5249, #entries .. "/" .. sum)

        -- 平滑序列已随 metrics 导出（曲线渲染与峰值检测同源），top1 应为全局平滑最大
        local b, sm = r.metrics.count.buckets, r.metrics.count.smoothed
        local smax, rawmax = 0, 0
        for i = 1, r.n do
            if (sm[i] or 0) > smax then smax = sm[i] end
            if (b[i] or 0) > rawmax then rawmax = b[i] end
        end
        local p = r.peaks.count
        check("E2 top1 为全局平滑最大", #p >= 1 and math.abs(p[1].value - smax) < 1e-9,
            #p .. "/" .. (p[1] and p[1].value) .. "/" .. smax)
        check("E3 峰桶位于高值区", (b[p[1].bucket] or 0) >= rawmax * 0.5,
            (b[p[1].bucket] or 0) .. "/" .. rawmax)
        print(string.format("INFO 实抓 top1: %s  条数 %d  平滑 %.1f（rawmax %d）",
            dt.format_time(p[1].time), p[1].count, p[1].value, rawmax))
    end
end

-- ============ 汇总 ============

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
