-- 跨源弹幕时间轴对齐测试：纯算法模块（timeline_align.compute）+ 管线集成（收集期应用平移）
-- 运行：mpv.com --no-config --idle=once --script=<本文件>

local ROOT = "D:/software/mpv-lazy/portable_config/scripts/uosc_danmaku"
package.path = ROOT .. "/?.lua;" .. package.path

local talign = require("modules/timeline_align")

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

local function entry(t, text)
    return { time = t, text = text }
end

-- 共享文本池：n 条文本，第 i 条基准时间 i*7
local function shared_pool(n)
    local texts, times = {}, {}
    for i = 1, n do
        texts[i] = string.format("共享弹幕%04d", i)
        times[i] = i * 7
    end
    return texts, times
end

-- 基准源数据：shared 全量 + extra_uniq 条独有弹幕
local function make_base(texts, times, extra_uniq)
    local entries = {}
    for i, tx in ipairs(texts) do entries[#entries + 1] = entry(times[i], tx) end
    for i = 1, extra_uniq or 0 do
        entries[#entries + 1] = entry(5000 + i, string.format("基准独有%03d", i))
    end
    return entries
end

-- 待对齐源数据：shared 前 take 条整体漂移 drift 秒
local function make_other(texts, times, drift, take)
    local entries = {}
    for i = 1, take or #texts do entries[#entries + 1] = entry(times[i] + drift, texts[i]) end
    return entries
end

-- ============ 纯算法模块 ============

-- 1. 基本：+90s 漂移 → shift=-90，diag 完整
do
    local texts, times = shared_pool(100)
    local result = talign.compute({
        { url = "http://base", entries = make_base(texts, times, 50) },
        { url = "http://other", entries = make_other(texts, times, 90) },
    })
    local diag = result.diag[1]
    check("1 检出漂移并整源平移",
        result.shifts["http://other"] == -90 and result.baseline == "http://base"
            and diag and diag.applied and diag.drift == 90 and diag.votes == 100
            and diag.match_count == 100)
    check("1b 基准源无平移", result.shifts["http://base"] == nil)
end

-- 2. 偏移 0.4s 取整为 0 → 低于触发阈值不平移
do
    local texts, times = shared_pool(100)
    local result = talign.compute({
        { url = "http://base", entries = make_base(texts, times, 50) },
        { url = "http://other", entries = make_other(texts, times, 0.4) },
    })
    local diag = result.diag[1]
    check("2 亚秒漂移不平移",
        result.shifts["http://other"] == nil and diag and not diag.applied
            and diag.reason and diag.reason:find("低于阈值", 1, true))
end

-- 3. 文本重合率不足（50/100=0.5 < 显式 0.8）→ 跳过（默认 0.3 下 0.5 会放行，
--     由 timeline_align_real_test 按实抓数据校准默认值，此处显式传严格值验证门槛）
do
    local texts, times = shared_pool(100)
    local other = make_other(texts, times, 90, 50)
    for i = 1, 50 do other[#other + 1] = entry(3000 + i, string.format("杂项文本%03d", i)) end
    local result = talign.compute({
        { url = "http://base", entries = make_base(texts, times, 50) },
        { url = "http://other", entries = other },
    }, { min_match_ratio = 0.8 })
    local diag = result.diag[1]
    check("3 重合率不足跳过",
        result.shifts["http://other"] == nil and diag and not diag.applied
            and diag.reason and diag.reason:find("重合率", 1, true))
end

-- 4. 偏移票分散（10 个偏移各 10 票，集中度 0.1 < 0.15）→ 跳过
do
    local texts, times = shared_pool(100)
    local other = {}
    for i, tx in ipairs(texts) do other[#other + 1] = entry(times[i] + (i % 10) + 10, tx) end
    local result = talign.compute({
        { url = "http://base", entries = make_base(texts, times, 0) },
        { url = "http://other", entries = other },
    })
    local diag = result.diag[1]
    check("4 偏移集中度不足跳过",
        result.shifts["http://other"] == nil and diag and not diag.applied
            and diag.reason and diag.reason:find("集中度", 1, true))
end

-- 5. 有效票率不足（1000 条只有 5 票同偏移，5/1000 < 0.05）→ 跳过
do
    local texts, times = shared_pool(1000)
    local other = {}
    for i, tx in ipairs(texts) do other[#other + 1] = entry(times[i] + (i % 200) + 10, tx) end
    local result = talign.compute({
        { url = "http://base", entries = make_base(texts, times, 1000) },
        { url = "http://other", entries = other },
    })
    local diag = result.diag[1]
    check("5 有效票率不足跳过",
        result.shifts["http://other"] == nil and diag and not diag.applied
            and diag.reason and diag.reason:find("有效票率", 1, true))
end

-- 6. 归一化：ASCII 大小写/空白/标点 + CJK 标点差异不影响命中
do
    local result = talign.compute({
        { url = "http://a", entries = {
            entry(100, "Hello World!"), entry(200, "前方高能！！"), entry(300, "2333"),
        } },
        { url = "http://b", entries = {
            entry(120, "helloworld"), entry(220, "前方高能"), entry(320, "2333？"),
        } },
    })
    check("6 归一化命中同文本", result.shifts["http://b"] == -20)
end

-- 7. transform 回调（简繁归一）：淚目 ↔ 泪目
do
    local result = talign.compute({
        { url = "http://a", entries = { entry(100, "泪目"), entry(200, "神作") } },
        { url = "http://b", entries = { entry(115, "淚目"), entry(215, "神作") } },
    }, {
        transform = function(text)
            return (text:gsub("淚", "泪"))
        end,
    })
    check("7 transform 简繁归一命中", result.shifts["http://b"] == -15)
end

-- 8. 基准=条数最多（与 URL 字典序相反）；平票取最小偏移
do
    local texts, times = shared_pool(100)
    local result = talign.compute({
        { url = "http://a", entries = make_other(texts, times, 30) }, -- 100 条
        { url = "http://z", entries = make_base(texts, times, 100) }, -- 200 条，字典序更晚
    })
    check("8a 基准取条数最多源", result.baseline == "http://z" and result.shifts["http://a"] == -30)

    local other = {} -- 50 条 +5、50 条 +7 → 平票取 +5
    for i, tx in ipairs(texts) do
        other[#other + 1] = entry(times[i] + (i <= 50 and 5 or 7), tx)
    end
    local result2 = talign.compute({
        { url = "http://a", entries = make_base(texts, times, 0) },
        { url = "http://b", entries = other },
    })
    check("8b 平票取最小偏移",
        result2.baseline == "http://a" and result2.shifts["http://b"] == -5)
end

-- 9. 单源 / 空输入 → 空结果
do
    local r1 = talign.compute({ { url = "http://a", entries = { entry(1, "x") } } })
    local r2 = talign.compute({})
    local r3 = talign.compute(nil)
    check("9 单源与空输入空结果",
        next(r1.shifts) == nil and r1.baseline == nil
            and next(r2.shifts) == nil and next(r3.shifts) == nil)
end

-- 10. 双重校正防护：输入为生效时间（已含 -90 手动补偿的 +90 漂移）→ 检出漂移 0 不再平移
do
    local texts, times = shared_pool(100)
    local result = talign.compute({
        { url = "http://base", entries = make_base(texts, times, 50) },
        { url = "http://other", entries = make_other(texts, times, 0) }, -- 90 - 90 = 0
    })
    check("10 已补偿源不再二次平移",
        result.shifts["http://other"] == nil)
end

-- 15. opts.skip：跳过的源不产生平移/诊断（调用方保留旧校正量），但仍参与基准选择
do
    local texts, times = shared_pool(100)
    local result = talign.compute({
        { url = "http://base", entries = make_base(texts, times, 50) },
        { url = "http://other", entries = make_other(texts, times, 90) },
    }, { skip = { ["http://other"] = true } })
    check("15 skip 源不参与平移计算",
        result.shifts["http://other"] == nil and #result.diag == 0)

    -- skip 条数最多的源 → 仍当选基准，另一源照常对齐到它
    local result2 = talign.compute({
        { url = "http://small", entries = make_other(texts, times, 30, 60) },
        { url = "http://big", entries = make_base(texts, times, 100) },
    }, { skip = { ["http://big"] = true } })
    check("15b skip 源仍可当选基准",
        result2.baseline == "http://big" and result2.shifts["http://small"] == -30)
end

-- ============ 管线集成 ============

show_message = function() end -- parse 空弹幕分支/导出提示会调 OSD，测试环境打桩
require("modules/options")
require("modules/utils")
require("modules/parse")

local function dm(t, text)
    return { time = t, type = 1, size = 25, color = 0xFFFFFF, text = text }
end

local function find_event(matcher)
    for _, ev in ipairs(COMMENTS) do
        if matcher(ev) then return ev end
    end
    return nil
end

local function build_two_sources()
    local base_data, other_data = {}, {}
    for i = 1, 100 do
        base_data[#base_data + 1] = dm(i * 7, string.format("共享弹幕%04d", i))
        other_data[#other_data + 1] = dm(i * 7 + 90, string.format("共享弹幕%04d", i))
    end
    for i = 1, 50 do
        base_data[#base_data + 1] = dm(5000 + i, string.format("基准独有%03d", i))
    end
    other_data[#other_data + 1] = dm(1234 + 90, "B源独有弹幕")
    return {
        ["test://base"] = { from = "user_custom", data = base_data },
        ["test://other"] = { from = "user_custom", data = other_data },
    }
end

-- 11. 多源叠加：+90s 漂移源被整源前移，独有弹幕落到基准时间轴
do
    -- 关闭智能密度与相似度合并以隔离断言：合成文本仅尾部数字不同（共享弹幕0001~0100），
    -- 会被 pakku 相似度通道互相并簇、代表性文本与簇时间不确定，与对齐无关
    options.density_control = "off"
    options.merge_enabled = false
    DANMAKU = { sources = build_two_sources(), count = 2 }
    COMMENTS = {}
    convert_danmaku_to_ass_events(true)
    local marker = find_event(function(ev)
        return ev.text and ev.text:find("B源独有弹幕", 1, true)
    end)
    check("11a 漂移源独有弹幕对齐到基准时间轴",
        marker ~= nil and math.floor((marker.start_time or -1) + 0.5) == 1234)
    check("11b align_shift 写回源记录",
        DANMAKU.sources["test://other"].align_shift == -90
            and DANMAKU.sources["test://base"].align_shift == 0)
    local n_shared, all_at_7 = 0, true
    for _, ev in ipairs(COMMENTS) do
        if ev.text and ev.text:find("共享弹幕0001", 1, true) then
            n_shared = n_shared + 1
            if math.floor((ev.start_time or -1) + 0.5) ~= 7 then all_at_7 = false end
        end
    end
    check("11c 同文本双源对齐后同落基准位", n_shared == 2 and all_at_7)
end

-- 12. options.timeline_align=false 关闭：不平移且清残留
do
    options.timeline_align = false
    DANMAKU = { sources = build_two_sources(), count = 2 }
    COMMENTS = {}
    convert_danmaku_to_ass_events(true)
    local marker = find_event(function(ev)
        return ev.text and ev.text:find("B源独有弹幕", 1, true)
    end)
    check("12 关闭后不平移",
        marker ~= nil and math.floor((marker.start_time or -1) + 0.5) == 1324
            and DANMAKU.sources["test://other"].align_shift == nil)
    options.timeline_align = true
end

-- 13. 钳 0：早期弹幕平移后为负 → 落 0
do
    local base_data, other_data = {}, {}
    for i = 1, 100 do
        base_data[#base_data + 1] = dm(i * 7, string.format("共享弹幕%04d", i))
        other_data[#other_data + 1] = dm(i * 7 + 90, string.format("共享弹幕%04d", i))
    end
    for i = 1, 10 do base_data[#base_data + 1] = dm(4000 + i, string.format("基准独有%03d", i)) end
    other_data[#other_data + 1] = dm(50, "早期独有弹幕") -- 50 - 90 < 0
    DANMAKU = { sources = {
        ["test://base"] = { from = "user_custom", data = base_data },
        ["test://other"] = { from = "user_custom", data = other_data },
    }, count = 2 }
    COMMENTS = {}
    convert_danmaku_to_ass_events(true)
    local early = find_event(function(ev)
        return ev.text and ev.text:find("早期独有弹幕", 1, true)
    end)
    check("13 负时间钳 0",
        early ~= nil and early.start_time == 0
            and DANMAKU.sources["test://other"].align_shift == -90)
end

-- 14. XML 导出同口径对齐（独立代码路径）
do
    local tmp = ROOT .. "/tests/talign_tmp_export.xml"
    DANMAKU = { sources = build_two_sources(), count = 2 }
    local ok = convert_danmaku_to_xml(tmp)
    local content = ok and read_file(tmp) or ""
    local hit = content:find('p="1234,', 1, false) ~= nil
        and content:find("B源独有弹幕", 1, true) ~= nil
    check("14 XML 导出按对齐时间轴", hit)
    os.remove(tmp)
end

-- 16. pin 流程：对齐介入后手动设延迟的源保留校正量，增量不被投票抹平；输入 0 恢复自动
do
    DANMAKU = { sources = build_two_sources(), count = 2 }
    COMMENTS = {}
    convert_danmaku_to_ass_events(true)
    check("16a 首次对齐写回校正量",
        DANMAKU.sources["test://other"].align_shift == -90)

    -- 模拟 set_danmaku_delay 在对齐介入后的行为：输入 +10 → 置 pin + 写手动段
    local other = DANMAKU.sources["test://other"]
    other.delay_segments = { { start = 0, delay = 10 } }
    other.align_pinned = true
    convert_danmaku_to_ass_events(true)
    local marker = find_event(function(ev)
        return ev.text and ev.text:find("B源独有弹幕", 1, true)
    end)
    check("16b pin 后手动增量叠加生效",
        marker ~= nil and math.floor((marker.start_time or -1) + 0.5) == 1244
            and other.align_shift == -90)

    -- 模拟输入 0：清空手动段并解除 pin → 恢复自动对齐
    other.delay_segments = {}
    other.align_pinned = nil
    convert_danmaku_to_ass_events(true)
    marker = find_event(function(ev)
        return ev.text and ev.text:find("B源独有弹幕", 1, true)
    end)
    check("16c 输入 0 重置回自动对齐",
        marker ~= nil and math.floor((marker.start_time or -1) + 0.5) == 1234
            and other.align_shift == -90 and other.align_pinned == nil)
end

-- 16d. 对齐介入前已有的手动补偿（如历史记录带入，无 pin）：漂移≈0 不产生新平移
do
    local sources = build_two_sources()
    sources["test://other"].delay_segments = { { start = 0, delay = -90 } }
    DANMAKU = { sources = sources, count = 2 }
    COMMENTS = {}
    convert_danmaku_to_ass_events(true)
    local marker = find_event(function(ev)
        return ev.text and ev.text:find("B源独有弹幕", 1, true)
    end)
    check("16d 对齐前手动补偿不二次平移",
        marker ~= nil and math.floor((marker.start_time or -1) + 0.5) == 1234
            and DANMAKU.sources["test://other"].align_shift == 0)
end

-- 17. 片尾附加内容不动正文：源 = 正文（与基准同轴）+ 尾部塞同番剧窄簇内容（如下一集
--     预告，簇内文本与基准预告文本逐条同构）→ 尾簇票数虽压过正文的 0 秒票，但支持
--     弹幕只集中在尾部窄窗（宽度 29s / 跨度 2029s），支持跨度门槛拒绝整源平移，
--     正文保持原位。若无此门槛，源会被整体 -570s 拉到预告簇时间轴上（正文全毁）。
do
    local texts, times = shared_pool(150)
    local base = make_base(texts, times, 0)
    for j = 1, 30 do
        base[#base + 1] = entry(1430 + j, string.format("预告弹幕%02d", j)) -- 基准侧预告簇
    end
    local other = {}
    for i = 1, 10 do other[#other + 1] = entry(times[i], texts[i]) end -- 正文同轴：10 票投 0
    for j = 1, 30 do -- 尾部窄簇：预告文本 ×4 重复，同构偏移 +570，120 票
        for _ = 1, 4 do other[#other + 1] = entry(2000 + j, string.format("预告弹幕%02d", j)) end
    end
    local result = talign.compute({
        { url = "http://base", entries = base },
        { url = "http://other", entries = other },
    })
    local diag = result.diag[1]
    check("17a 尾部窄簇假偏移被检出（drift/votes 反映簇结构）",
        diag and diag.drift == 570 and diag.votes == 120 and diag.match_count == 130)
    check("17b 支持跨度过窄拒绝平移，正文保持原位",
        result.shifts["http://other"] == nil and not diag.applied
            and diag.reason and diag.reason:find("跨度过窄", 1, true))
end

-- 17c. 对照：真实的全片恒定大偏移（片头贴长广告等）支持弹幕从早到晚全程分布，
--      支持跨度门槛不拦截，仍整源平移
do
    local texts, times = shared_pool(100)
    local result = talign.compute({
        { url = "http://base", entries = make_base(texts, times, 0) },
        { url = "http://other", entries = make_other(texts, times, 1400) },
    })
    check("17c 大偏移全片支持仍平移",
        result.shifts["http://other"] == -1400 and result.diag[1].applied)
end

if failures > 0 then
    print(failures .. " FAILURES")
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
