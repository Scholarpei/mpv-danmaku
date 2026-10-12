-- 渲染等价性测试：新渲染（构建期 bake + 渲染期坐标插值）与旧渲染（每帧正则变换）
-- 对同一 COMMENTS 在 pos 采样序列上的输出必须逐字节相等。参考实现为旧 render.lua
-- 41-133 行字符串构建部分的忠实快照（改造前代码），勿随新实现更新。
-- 运行：mpv.com --idle=once --no-config --script=<本文件>

local ROOT = "D:/software/mpv-lazy/portable_config/scripts/uosc_danmaku"
package.path = ROOT .. "/?.lua;" .. package.path

-- parse.lua 空弹幕分支会调 render.lua 的 show_message，测试环境打桩
show_message = function() end

require("modules/options")
-- 黑名单空载：等价测试不涉及过滤语义（两侧实现遍历的是同一份过滤后的 COMMENTS）
options.blacklist_path = ""

require("modules/utils")
require("modules/parse")
require("modules/render")

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
        if detail then print("  详情: " .. tostring(detail)) end
    end
end

-- ---------- 参考实现（旧 render.lua 快照，勿改） ----------
local unpack_ref = unpack or table.unpack

local function ref_realtime_position_text(event, pos, displayarea)
    if not event.move then
        local _, current_y = unpack_ref(event.pos)
        if not current_y or tonumber(current_y) > displayarea then return end
        if event.style ~= "SP" and event.style ~= "MSG" then
            return string.format("{\\an8}%s", event.text)
        else
            return string.format("{\\an7}%s", event.text)
        end
    end

    local x1, y1, x2, y2 = unpack_ref(event.move)
    local duration = event.end_time - event.start_time
    local progress = (pos - event.start_time) / duration
    local current_x = tonumber(x1 + (x2 - x1) * progress)
    local current_y = tonumber(y1 + (y2 - y1) * progress)

    local clean_text = event.text:gsub("\\move%(.-%)", "")
    if current_y > displayarea then return end
    if event.style ~= "SP" and event.style ~= "MSG" then
        return string.format("{\\pos(%.1f,%.1f)\\an8}%s", current_x, current_y, clean_text)
    else
        return string.format("{\\pos(%.1f,%.1f)\\an7}%s", current_x, current_y, clean_text)
    end
end

local osd_width_ref, osd_height_ref = 0, 0 -- 测试环境与 render.lua 模块初值一致（ratio 分支不进入）

local function ref_build(pos)
    local fontname = options.fontname
    local fontsize = options.fontsize
    local opacity = tonumber(options.opacity)
    local alpha = string.format("%02X", (1 - (opacity or 0)) * 255)

    local width, height = 1920, 1080
    local ratio = osd_width_ref / osd_height_ref
    if width / height < ratio then
        height = width / ratio
        fontsize = options.fontsize - ratio * 2
    end

    local ass_events_low = {}
    local ass_events_high = {}
    local max_display = math.max(options.scrolltime, options.fixtime)
    local window_start = pos - max_display

    local lo = binary_search(COMMENTS, window_start, function(item) return item.start_time end)

    local re_entity = "&#%d+;"
    local re_fs = "\\fs(%d+)"
    local ass_prefix = string.format("{\\rDefault\\fn%s\\fs%d\\c&HFFFFFF&\\alpha&H%s\\bord%s\\shad%s\\b%s\\q2}",
        fontname, fontsize, alpha, options.outline, options.shadow, options.bold and "1" or "0")

    for i = lo, #COMMENTS do
        local event = COMMENTS[i]
        if not event then break end

        if event.start_time > pos then break end
        if event.end_time >= pos then
            local text = ref_realtime_position_text(event, pos, height * options.displayarea)
            if text then
                text = text:gsub(re_entity, "")
            end

            if text and text:match(re_fs) then
                text = text:gsub(re_fs, function(size)
                    local n = tonumber(size) or 0
                    return string.format("\\fs%d", math.floor(n * 1.5))
                end)
            end

            local event_font_prefix = ""
            if event.font_size then
                local configured_size = tonumber(options.fontsize) or fontsize
                local adjusted_size = math.max(1, math.floor(event.font_size + fontsize - configured_size))
                event_font_prefix = string.format("{\\fs%d}", adjusted_size)
            end
            local ass_text = text and (ass_prefix .. event_font_prefix .. text)
            if ass_text then
                if event.layer == nil or tonumber(event.layer) == 0 then
                    table.insert(ass_events_low, ass_text)
                else
                    table.insert(ass_events_high, ass_text)
                end
            end
        end
    end

    return table.concat(ass_events_low, '\n'), table.concat(ass_events_high, '\n')
end

-- ---------- 刁钻数据（经真实管线构建 COMMENTS） ----------
local function dm(t, text, dtype, size)
    return { time = t, type = dtype or 1, size = size or 25, color = 0xFFFFFF, text = text }
end

local data = {}
-- 1. 普通滚动（多轨道：同刻多条挤不同 lane）。普通滚动弹幕N 互相似会被合并，
-- 用独特词组保证独立存活
local roll_words = { "苹果", "香蕉", "西瓜", "葡萄", "橘子", "菠萝", "荔枝", "芒果",
    "柠檬", "柚子", "樱桃", "草莓" }
for i = 1, 12 do data[#data + 1] = dm(20.0 + i * 0.1, roll_words[i] .. "味的汽水") end
-- 2. 双重转义实体：收集期单趟解码后残留 &#65;（渲染期再剥一趟兜底的语义）
data[#data + 1] = dm(30.0, "&#38;#65;&#38;#66;实体双重转义")
data[#data + 1] = dm(30.5, "普通实体&#65;&#x4e2d;混合")
-- 3. 字面 \fs12：ass_escape 后 \\fs12 仍含 \fs 子串，命中 1.5 倍放大分支
data[#data + 1] = dm(31.0, "\\fs12字号字面量")
data[#data + 1] = dm(31.5, "\\fs7七号\\fs33三三")
-- 4. 合并簇 xN 后缀（merged_x_suffix 样式化 {\b1\i1}xN 活标签）
for _, t in ipairs({ 40.0, 40.2, 40.4, 40.6, 40.8 }) do data[#data + 1] = dm(t, "哈哈哈哈") end
-- 5. 繁体原文（chConvert 默认 1 收集期转简体，渲染输出比对含转换后文本）
data[#data + 1] = dm(50.0, "這是繁體彈幕")
-- 6. 顶/底固定弹幕（窗口内文本不变——high 层）。文本互不相似防 pakku 合并
data[#data + 1] = dm(60.0, "天花板红气球一号", 5)
data[#data + 1] = dm(62.0, "地毯弹珠两颗", 4)
data[#data + 1] = dm(65.0, "窗帘\\fs9飘带", 5)
-- 7. 特殊字符：大括号/反斜杠/换行（ass_escape 四连 gsub 路径）
data[#data + 1] = dm(70.0, "大{括号}与\\反斜杠")
data[#data + 1] = dm(70.5, "换行\n弹幕")
-- 8. 字号差异（font_size 分支 → event_font_prefix）
data[#data + 1] = dm(75.0, "大字号弹幕", 1, 36)
data[#data + 1] = dm(75.5, "小字号弹幕", 1, 18)

DANMAKU = { sources = { ["equiv://x"] = { from = "user_custom", data = data } }, count = 1 }
convert_danmaku_to_ass_events()

local n_events = COMMENTS and #COMMENTS or 0
check("管线构建出弹幕事件", n_events > 0, "n=" .. tostring(n_events))

-- 预计算字段存在性
local n_body, n_fixed = 0, 0
for _, ev in ipairs(COMMENTS) do
    if ev.move then n_body = n_body + 1; check_body = ev.render_body end
    if ev.pos then n_fixed = n_fixed + 1 end
end
check("滚动事件带 render_body", n_body > 0 and check_body ~= nil)
check("固定事件带 render_fixed", n_fixed >= 3)

-- ---------- pos 采样逐字节比对 ----------
local mismatches = 0
local first_diff = nil
local pos = 0.0
while pos <= 90.0 do
    local ref_low, ref_high = ref_build(pos)
    local new_low, new_high = build_visible_strings(pos)
    if ref_low ~= new_low then
        mismatches = mismatches + 1
        first_diff = first_diff or ("pos=" .. string.format("%.2f", pos) .. " low 不等")
    end
    if ref_high ~= new_high then
        mismatches = mismatches + 1
        first_diff = first_diff or ("pos=" .. string.format("%.2f", pos) .. " high 不等")
    end
    pos = pos + 0.2
end
-- 细步进局部覆盖窗口进出边界（合并簇波头 40s 附近）
for p = 38.0, 44.0, 0.04 do
    local ref_low, ref_high = ref_build(p)
    local new_low, new_high = build_visible_strings(p)
    if ref_low ~= new_low or ref_high ~= new_high then
        mismatches = mismatches + 1
        first_diff = first_diff or ("pos=" .. string.format("%.3f", p))
    end
end

check("pos 采样序列逐字节等价（0-90s 步进 0.2 + 边界 0.04）", mismatches == 0,
    mismatches .. " 处不一致，首个: " .. tostring(first_diff))

-- 样式参数变化后仍等价（prefix 缓存失效路径）
options.opacity = 0.4
options.bold = true
do
    local m2 = 0
    for p = 15.0, 80.0, 1.7 do
        local rl, rh = ref_build(p)
        local nl, nh = build_visible_strings(p)
        if rl ~= nl or rh ~= nh then m2 = m2 + 1 end
    end
    check("样式参数变化（opacity/bold）后仍逐字节等价", m2 == 0, m2 .. " 处不一致")
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
-- os.exit 直杀：mpv 正常 quit 的关机路径在 Windows 控制台代理下偶发挂起（测试环境已知问题）
os.exit(failures > 0 and 1 or 0)
