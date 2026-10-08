-- pakku_merge 单元测试（自断言，输出 PASS/FAIL 行）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local pakku = require("modules/pakku_merge")

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

local function dm(time, text, dtype, color)
    return { time = time, type = dtype or 1, size = 25, color = color or 0xFFFFFF,
             text = text, source = "test" }
end

local DEFAULT_FORCELIST = pakku.parse_forcelist("^2333+=>23333|^666+=>66666")
local function run(list, cfg)
    cfg = cfg or {}
    cfg.window = cfg.window or 30
    cfg.forcelist = cfg.forcelist or DEFAULT_FORCELIST
    cfg.use_pinyin = cfg.use_pinyin or false
    return pakku.merge(list, cfg)
end

-- ---------- normalize ----------
check("normalize 全角数字+全角感叹号+套路规则",
    pakku.normalize("２３３３３！", DEFAULT_FORCELIST) == "23333")
check("normalize CJK 间空格删除", pakku.normalize("哭 死", {}) == "哭死")
check("normalize 尾部标点剥离", pakku.normalize("前方高能。。。", {}) == "前方高能")
check("normalize 全尾标点保留原样", pakku.normalize("。。。", {}) == "。。。")
check("normalize 半角/全角感叹号同形",
    pakku.normalize("什么!", {}) == pakku.normalize("什么！", {}))

-- ---------- 合并 fixture ----------
-- 1. 同刻完全重复：1 簇、无后缀（count=2 且同刻，插件原约定）
do
    local out = run({ dm(10, "哈哈哈"), dm(10, "哈哈哈") })
    check("1 同刻重复合并", #out == 1 and out[1].merge_count == 2 and out[1].text == "哈哈哈")
end

-- 2. 短串比例门：哈哈哈哈 vs 哈哈哈哈哈
do
    local out = run({ dm(10, "哈哈哈哈"), dm(10, "哈哈哈哈哈") })
    check("2 多重集距离合并短串", #out == 1 and out[1].merge_count == 2)
end

-- 3. 拼音谐音：泪目 vs 累目（依赖字典，缺失时 SKIP）
do
    if pakku.pinyin_available() then
        local out = run({ dm(10, "泪目"), dm(10.2, "累目") }, { use_pinyin = true })
        check("3 拼音谐音合并", #out == 1 and out[1].merge_count == 2)
    else
        print("SKIP 3 拼音谐音合并（无字典）")
    end
end

-- 4. 套路规则：2333 刷屏统一改写后合并，文本 23333、x3 后缀
do
    local out = run({ dm(10, "2333333"), dm(10.1, "23333"), dm(10.2, "233333") })
    check("4 套路规则合并",
        #out == 1 and out[1].merge_count == 3 and out[1].text == "23333x3")
end

-- 5. 多重集超限走余弦：哈×10 vs 哈×4（cos²=1）
do
    local out = run({ dm(10, "哈哈哈哈哈哈哈哈哈哈"), dm(10.2, "哈哈哈哈") })
    check("5 二元组余弦合并", #out == 1 and out[1].merge_count == 2)
end

-- 6. 跨模式合并 + cross_mode=false 对照
do
    local out = run({ dm(10, "哈哈哈", 1), dm(10.5, "哈哈哈", 4) })
    check("6a 跨模式合并且模式提升为底部", #out == 1 and out[1].type == 4)
    local out2 = run({ dm(10, "哈哈哈", 1), dm(10.5, "哈哈哈", 4) }, { cross_mode = false })
    check("6b 关闭跨模式不合并", #out2 == 2)
end

-- 7. 窗口过期：t=0/40、窗口 30 → 2 簇
do
    local out = run({ dm(0, "哈哈哈"), dm(40, "哈哈哈") })
    check("7 窗口过期不合并", #out == 2)
end

-- 8. 反例：内容无关的弹幕不合并
do
    local out = run({ dm(10, "今天天气真好"), dm(10.5, "明天也要加油") })
    check("8 反例不合并", #out == 2)
end

-- 9. 模式提升：滚动+顶部+底部 → 输出底部
do
    local out = run({ dm(10, "哈哈哈", 1), dm(10.3, "哈哈哈", 5), dm(10.6, "哈哈哈", 4) })
    check("9 模式提升为底部", #out == 1 and out[1].type == 4 and out[1].merge_count == 3)
end

-- 10. 输出有序性：代表项(第20百分位)时间可晚于后簇，输出必须非降
do
    local list = {
        dm(10.0, "AAAAA"), dm(10.05, "BBBBB"), dm(10.1, "AAAAA"),
        dm(10.2, "AAAAA"), dm(10.3, "AAAAA"), dm(10.35, "CCCCC"), dm(10.4, "AAAAA"),
    }
    table.sort(list, function(a, b) return a.time < b.time end)
    local out = run(list)
    local ok = #out == 3
    for i = 2, #out do
        if out[i].time < out[i - 1].time then ok = false break end
    end
    check("10 输出时间非降序", ok)
end

-- 11. merged_x_suffix 标记：仅引擎生成 ×N 后缀时置位（parse 侧据此样式化，避免误样式化用户原文）
do
    local a = run({ dm(10, "哈哈哈") })                                   -- n=1 单条无后缀
    local b = run({ dm(10, "哈哈哈"), dm(10, "哈哈哈") })                 -- n=2 同刻无后缀
    local c = run({ dm(10, "哈哈哈"), dm(10.5, "哈哈哈") })               -- n=2 非同刻有后缀
    local d = run({ dm(10, "哈哈哈"), dm(10.1, "哈哈哈"), dm(10.2, "哈哈哈") }) -- n=3 有后缀
    check("11 merged_x_suffix 标记",
        a[1].merged_x_suffix == nil and b[1].merged_x_suffix == nil
        and c[1].merged_x_suffix == true and d[1].merged_x_suffix == true)
end

-- 12. 相似度档位参数（cfg.max_dist / cfg.max_cosine）：
-- L 对多重集距离 4、环形二元组 cos²=49；F 对多重集距离 8（gram 交集小、余弦兜不住）
do
    local L1, L2 = "abcdefghij", "abcdeXXhij"
    local F1, F2 = "abcdefghij", "abcdXXXXij"
    check("12a light 档不合并轻微差异",
        #run({ dm(10, L1), dm(10.2, L2) }, { max_dist = 2, max_cosine = 60 }) == 2)
    check("12b medium 档合并轻微差异",
        #run({ dm(10, L1), dm(10.2, L2) }, { max_dist = 5, max_cosine = 45 }) == 1)
    check("12c medium 档不合并大差异",
        #run({ dm(10, F1), dm(10.2, F2) }, { max_dist = 5, max_cosine = 45 }) == 2)
    check("12d strong 档合并大差异",
        #run({ dm(10, F1), dm(10.2, F2) }, { max_dist = 10, max_cosine = 35 }) == 1)
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
mp.commandv("quit")
