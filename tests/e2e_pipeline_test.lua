-- 端到端管线测试：直接驱动 convert_danmaku_to_ass_events（黑名单门 → 模式转换 → pakku 合并 → 密度控制 → 布局）
-- 运行前写入 tests/black_e2e.txt（内容：敏感词）
-- 运行：mpv.com --no-config --idle=once --script=<本文件> --script-opts=e2e_pipeline_test-blacklist_path=<black_e2e.txt 路径>

local ROOT = "D:/software/mpv-lazy/portable_config/scripts/uosc_danmaku"
package.path = ROOT .. "/?.lua;" .. package.path

-- parse.lua 会在空弹幕分支调用 render.lua 的 show_message，测试环境不渲染，打桩
show_message = function() end

require("modules/options")
require("modules/utils")
require("modules/parse")

-- 运行时覆盖（管线读取 convert 时刻的实时值）。
-- density_control 必须显式声明 simple：默认已是 smart，D 节的随机丢弃断言依赖简单模式
options.convert_top_to_scroll = true
options.density_control = "simple"
options.max_screen_danmaku = 5

local function dm(t, text, dtype)
    return { time = t, type = dtype or 1, size = 25, color = 0xFFFFFF, text = text }
end

local data = {}
-- A. 相似合并簇：4×哈哈哈哈 + 1×哈哈哈哈哈
for _, t in ipairs({ 10.0, 10.2, 10.4, 10.6 }) do data[#data + 1] = dm(t, "哈哈哈哈") end
data[#data + 1] = dm(10.3, "哈哈哈哈哈")
-- B. 套路规则改写合并
for _, t in ipairs({ 20.0, 20.1, 20.2 }) do data[#data + 1] = dm(t, "2333333") end
-- C. 顶部弹幕转滚动（放远些：转滚动后显示 15s，避免落进 D 的密度窗口）
data[#data + 1] = dm(100.0, "固顶弹幕", 5)
-- D. 密度限制：12 条互不相似的弹幕挤进同一窗口，上限 5
local fruits = { "苹果", "香蕉", "西瓜", "葡萄", "橘子", "菠萝", "荔枝", "芒果", "柠檬", "柚子", "樱桃", "草莓" }
for i, w in ipairs(fruits) do data[#data + 1] = dm(40.0 + i * 0.05, w) end
-- E. 黑名单命中
data[#data + 1] = dm(50.0, "包含敏感词的弹幕测试")
-- F. 正常单条
data[#data + 1] = dm(60.0, "正常弹幕")
-- G2. 用户原文以 x数字 结尾且未被合并（不应被 ×N 样式化）
data[#data + 1] = dm(70.0, "太强了x3")

table.sort(data, function(a, b) return a.time < b.time end)
DANMAKU = { sources = { ["test://e2e"] = { from = "user_local", data = data } }, count = 1 }
COMMENTS = {}

convert_danmaku_to_ass_events(true)

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

local function count_events(pred)
    local n = 0
    for _, ev in ipairs(COMMENTS) do
        if pred(ev) then n = n + 1 end
    end
    return n
end

-- A：合并为 1 条、x5 后缀、字号增长
do
    local evs = {}
    for _, ev in ipairs(COMMENTS) do
        if ev.text and ev.text:find("哈", 1, true) then evs[#evs + 1] = ev end
    end
    check("A 相似合并 x5",
        #evs == 1 and evs[1].merge_count == 5 and evs[1].text:find("x5", 1, true)
            and evs[1].font_size > 50)
end

-- B：套路规则改写后合并，文本统一为 23333
do
    local evs = {}
    for _, ev in ipairs(COMMENTS) do
        if ev.text and ev.text:find("23333", 1, true) then evs[#evs + 1] = ev end
    end
    check("B 套路规则合并",
        #evs == 1 and evs[1].merge_count == 3 and evs[1].text:find("x3", 1, true))
end

-- C：顶部转滚动，↑ 前缀，R2L 样式
do
    local found = false
    for _, ev in ipairs(COMMENTS) do
        if ev.text and ev.text:find("↑固顶弹幕", 1, true) and ev.style == "R2L" then
            found = true
        end
    end
    check("C 顶部转滚动", found)
end

-- D：同屏上限 5，随机丢弃（滚动弹幕 start_time 会 floor(t+0.5) 取整，用 [40,42) 覆盖）
check("D 密度限制为 5",
    count_events(function(ev) return ev.start_time >= 40 and ev.start_time < 42 end) == 5)

-- E：黑名单命中被过滤
check("E 黑名单过滤", count_events(function(ev)
    return ev.text and ev.text:find("敏感词", 1, true)
end) == 0)

-- F：普通弹幕原样保留
do
    local evs = {}
    for _, ev in ipairs(COMMENTS) do
        if ev.text and ev.text:find("正常弹幕", 1, true) then evs[#evs + 1] = ev end
    end
    check("F 普通弹幕直通", #evs == 1 and evs[1].merge_count == 1)
end

check("G 总数 1+1+1+5+0+1+1=10", #COMMENTS == 10)

-- G2：原文以 x数字 结尾的未合并弹幕不加粗斜体（merged_x_suffix 改造的回归）
do
    local evs = {}
    for _, ev in ipairs(COMMENTS) do
        if ev.text and ev.text:find("太强了x3", 1, true) then evs[#evs + 1] = ev end
    end
    check("G2 原文x数字结尾不样式化",
        #evs == 1 and not evs[1].text:find("\\b1", 1, true))
end

-- H：合并统计全局（实际发生合并时 before > after）
check("H 合并统计 MERGE_STATS",
    MERGE_STATS ~= nil and MERGE_STATS.before > MERGE_STATS.after)

-- I：auto 模式按宽度转换：超阈值的顶部弹幕转滚动，短的保留原样
do
    DANMAKU = { sources = { ["test://e2e2"] = { from = "user_local", data = {
        dm(200.0, "这是一条非常长的顶部弹幕用于超过宽度阈值", 5),
        dm(200.5, "短", 5),
    } } }, count = 1 }
    options.max_screen_danmaku = 0
    options.convert_top_to_scroll = "auto"
    options.scroll_threshold = 100
    convert_danmaku_to_ass_events(true)
    local n_r2l, n_top = 0, 0
    for _, ev in ipairs(COMMENTS) do
        if ev.style == "R2L" and ev.text:find("↑", 1, true) then n_r2l = n_r2l + 1 end
        if ev.style == "TOP" then n_top = n_top + 1 end
    end
    check("I auto 模式按宽度转换", n_r2l == 1 and n_top == 1)
end

-- J：智能密度（pakku 式收缩+丢弃）。60 条互不相似 6 字滚动弹幕挤进 [40,42) 窗口：
-- 文本用连续码点生成、每条 6 个字符全不与其它条重复（规避合并四通道与套路/黑名单规则），
-- 等长 ⇒ 等速 ⇒ 车道可复用，收缩后的弹幕仍能通过布局落到最终事件。
-- strict={30,60}：第 ~13 条起 sum>30 触发收缩、~25 条起 sum>60 触发丢弃。
-- 不做总条数等值断言（布局车道耗尽的丢弃与密度丢弃不可区分）
do
    local function cjk(cp)
        return string.char(0xE0 + math.floor(cp / 4096),
            0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    local function make_wall()
        local list = {}
        for i = 1, 60 do
            local t = {}
            for j = 1, 6 do t[j] = cjk(0x4E00 + (i - 1) * 6 + (j - 1)) end
            list[i] = dm(40.0 + i * 0.02, table.concat(t))
        end
        return list
    end
    DANMAKU = { sources = { ["test://e2e3"] = { from = "user_local", data = make_wall() } }, count = 1 }
    options.density_control = "smart"
    options.density_level = "strict"
    convert_danmaku_to_ass_events(true)
    check("J 智能密度统计与收缩生效",
        DENSITY_STATS ~= nil and DENSITY_STATS.dropped > 0 and DENSITY_STATS.shrunk > 0
            and count_events(function(ev) return ev.font_size < 50 end) > 0)

    -- 对照：off 模式同数据无任何干预（未合并弹幕字号恰为基准 50）
    DANMAKU = { sources = { ["test://e2e4"] = { from = "user_local", data = make_wall() } }, count = 1 }
    options.density_control = "off"
    convert_danmaku_to_ass_events(true)
    check("Jb 对照 off 模式无干预",
        DENSITY_STATS == nil and count_events(function(ev) return ev.font_size < 50 end) == 0)
end

-- K：简繁转换（默认 1 转简体）与模式切换缓存失效。
-- 断言用 ev.clean_text（转换后、ASS 转义前）；Kb 的"还原原文"专抓缓存 mode-guard 缺失
-- （无守卫时旧缓存返回转换后文本）。繁简两条弹幕原文互不相似，不触发合并。
do
    local function ch_events()
        return count_events(function(ev)
            return ev.clean_text and (
                ev.clean_text:find("繁", 1, true) or ev.clean_text:find("简", 1, true)
                    or ev.clean_text:find("簡", 1, true))
        end)
    end
    local function has_text(needle)
        return count_events(function(ev)
            return ev.clean_text and ev.clean_text:find(needle, 1, true)
        end) == 1
    end
    DANMAKU = { sources = { ["test://e2e5"] = { from = "user_local", data = {
        dm(300.0, "這是繁體字彈幕"),
        dm(301.0, "简体字弹幕"),
    } } }, count = 1 }
    convert_danmaku_to_ass_events(true) -- chConvert 默认 1：這→这 體→体 彈→弹
    check("K 默认转简体",
        ch_events() == 2 and has_text("这是繁体字弹幕") and has_text("简体字弹幕"))

    options.chConvert = 0
    convert_danmaku_to_ass_events(true)
    check("Kb 切关还原原文（缓存失效）",
        ch_events() == 2 and has_text("這是繁體字彈幕") and has_text("简体字弹幕"))

    options.chConvert = 2
    convert_danmaku_to_ass_events(true) -- 简→簡 体→體 弹→彈；繁体原文恒等
    check("Kc 转繁体",
        ch_events() == 2 and has_text("這是繁體字彈幕") and has_text("簡體字彈幕"))

    options.chConvert = 1 -- 还原默认
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
mp.commandv("quit")
