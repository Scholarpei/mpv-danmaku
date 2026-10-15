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

-- Pure graph and calibration cases live in timeline_calibration_test.lua.
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

-- 16. 旧 pin 标志不再控制算法，手动层仍独立生效。
do
    DANMAKU = { sources = build_two_sources(), count = 2 }
    COMMENTS = {}
    convert_danmaku_to_ass_events(true)
    check("16a 首次对齐写回校正量",
        DANMAKU.sources["test://other"].align_shift == -90)

    -- 模拟旧版本留下的 pin 与手动段：新模型不再读取 pin。
    local other = DANMAKU.sources["test://other"]
    other.delay_segments = { { start = 0, delay = 10 } }
    other.align_pinned = true
    convert_danmaku_to_ass_events(true)
    local marker = find_event(function(ev)
        return ev.text and ev.text:find("B源独有弹幕", 1, true)
    end)
    check("16b 手动增量独立于自动分析",
        marker ~= nil and math.floor((marker.start_time or -1) + 0.5) == 1244
            and other.align_shift == -90)

    -- 模拟显式清除旧手动段。
    other.delay_segments = {}
    other.align_pinned = nil
    convert_danmaku_to_ass_events(true)
    marker = find_event(function(ev)
        return ev.text and ev.text:find("B源独有弹幕", 1, true)
    end)
    check("16c 清除旧手动段恢复相对时间",
        marker ~= nil and math.floor((marker.start_time or -1) + 0.5) == 1234
            and other.align_shift == -90 and other.align_pinned == nil)
end

-- 16d. 旧历史总延迟与自动分析保持兼容，不产生二次补偿。
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
            and DANMAKU.sources["test://other"].align_shift == -90)
end

-- Tail-only matches must not move the main timeline.
do
 local texts,times=shared_pool(150)
 local base=make_base(texts,times,0)
 local other={}
 for i=1,10 do other[#other+1]=entry(times[i],texts[i]) end
 for j=1,30 do
  base[#base+1]=entry(1430+j,'预告'..j)
  for _=1,4 do other[#other+1]=entry(2000+j,'预告'..j) end
 end
 local r=talign.compute({{url='a',entries=base},{url='b',entries=other}})
 check('tail-only cluster cannot align whole episode',r.members.a~=r.members.b and not r.shifts.b)
end

if failures > 0 then
    print(failures .. " FAILURES")
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
