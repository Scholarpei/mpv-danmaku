-- bilibili_match 单元测试（自断言，输出 PASS/FAIL 行）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local bm = require("modules/bilibili_match")

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

-- ---------- fixtures ----------
-- 合集投稿 63 P：S1 裸数字 01..23 + 24（OVA）、S2 【S2】00..24、S3 【S3】01..14
-- （照抄真实 BV1nJ396JEhH 的结构：S3 第 9 集在 p58）
local FRANCHISE = {}
do
    for i = 1, 23 do
        FRANCHISE[#FRANCHISE + 1] = { page = i, part = string.format("%02d", i), duration = 1430 + i }
    end
    FRANCHISE[#FRANCHISE + 1] = { page = 24, part = "24（OVA）", duration = 1500 }
    for i = 0, 24 do
        FRANCHISE[#FRANCHISE + 1] = { page = 25 + i, part = string.format("【S2】%02d", i), duration = 1420 + i }
    end
    for i = 1, 14 do
        FRANCHISE[#FRANCHISE + 1] = { page = 49 + i, part = string.format("【S3】%02d", i), duration = 1435 }
    end
    assert(#FRANCHISE == 63)
end

-- 单季投稿 14 P：裸数字 1..14（照抄真实 BV1smaP6zEqi）
local S3ONLY = {}
for i = 1, 14 do
    S3ONLY[#S3ONLY + 1] = { page = i, part = tostring(i), duration = 1435 }
end

-- 合并2季投稿 20 P：裸序号 "1".."19"（S3 11集 + S4夺还篇 8集）+ p20 MAD
-- （照抄真实 BV1wT8J6NEFS：分P按合集内序号编号，本地文件夹用全局集数
--   78..85，第二集 79 ↔ p13，两套编号体系差常量偏移 66）
local MERGED = {}
do
    local real_dur = { 2344, 2752, 2431, 2432, 2612, 1732, 2432, 3072 } -- p12..p19 真实时长
    for i = 1, 19 do
        MERGED[#MERGED + 1] = { page = i, part = tostring(i),
            duration = i >= 12 and real_dur[i - 11] or 2012 }
    end
    MERGED[#MERGED + 1] = { page = 20, part = "av2138【萌】『MAD』双子星公主 X 草莓棉花糖", duration = 234 }
    assert(#MERGED == 20)
end

-- MERGED 去掉 p14（页号保持 1..13, 15..20），用于仲裁回退用例
local MERGED_GAP = {}
for _, p in ipairs(MERGED) do
    if p.page ~= 14 then MERGED_GAP[#MERGED_GAP + 1] = p end
end

local function match(parts, o)
    o = o or {}
    o.parts = parts
    o.duration = o.duration or 1435 -- 与 S3 分P时长一致的本地文件
    return bm.match_bilibili_part(o)
end

-- ---------- parse_part_title ----------
do
    local s, e, sp
    s, e = bm.parse_part_title("【S3】09")
    check("parse 【S3】09", s == 3 and e == 9)
    s, e = bm.parse_part_title("【S2】00")
    check("parse 【S2】00", s == 2 and e == 0)
    s, e = bm.parse_part_title("S3E09")
    check("parse S3E09", s == 3 and e == 9)
    s, e = bm.parse_part_title("S3-09")
    check("parse S3-09", s == 3 and e == 9)
    s, e = bm.parse_part_title("第2季 第05话")
    check("parse 第2季 第05话", s == 2 and e == 5)
    s, e = bm.parse_part_title("9")
    check("parse 9 裸数字", s == nil and e == 9)
    s, e = bm.parse_part_title("09")
    check("parse 09 裸数字补零", s == nil and e == 9)
    s, e, sp = bm.parse_part_title("24（OVA）")
    check("parse 24（OVA）", s == nil and e == 24 and sp == true)
    s, e, sp = bm.parse_part_title("01 加长版")
    check("parse 01 加长版", s == nil and e == 1)
    s, e = bm.parse_part_title("第12话")
    check("parse 第12话", s == nil and e == 12)
    s, e = bm.parse_part_title("EP05")
    check("parse EP05", s == nil and e == 5)
    s, e = bm.parse_part_title("PV")
    check("parse PV 不可解析", s == nil and e == nil)
    s, e = bm.parse_part_title("番外篇")
    check("parse 番外篇 不可解析", s == nil and e == nil)
    s, e, sp = bm.parse_part_title("第9话 特别篇")
    check("parse 第9话 特别篇 special", s == nil and e == 9 and sp == true)
    _, _, sp = bm.parse_part_title("【S3】09")
    check("parse 【S3】09 非 special", sp == false)
end

-- ---------- match_bilibili_part ----------
-- 2. 合集、本地 (nil,9)、锚 {58,9}：锚点页加分 → p58（【S3】09）
do
    local m = match(FRANCHISE, { episode = 9, anchor_page = 58, anchor_episode = 9 })
    check("match 合集 nil季 第9集 锚p58 → p58", m and m.page == 58)
end

-- 3. 合集、本地 (nil,5)、锚 {58,9}：三候选并列（裸05/【S2】05/【S3】05），delta=54 仲裁
do
    local m = match(FRANCHISE, { episode = 5, anchor_page = 58, anchor_episode = 9 })
    check("match 合集 nil季 第5集 delta仲裁 → p54", m and m.page == 54)
end

-- 4. 合集、本地 (1,9)、锚 {9,9,季1}：【S2】09/【S3】09 被硬排除，裸 09 唯一 → p9
do
    local m = match(FRANCHISE, { season = 1, episode = 9,
        anchor_page = 9, anchor_episode = 9, anchor_season = 1 })
    check("match 合集 S1第9集 硬季过滤 → p9", m and m.page == 9)
end

-- 5. 合集、本地 (3,9)、无锚：显式季+集唯一高分 → p58
do
    local m = match(FRANCHISE, { season = 3, episode = 9 })
    check("match 合集 S3第9集 无锚 → p58", m and m.page == 58)
end

-- 6a. 单季、本地 (nil,9)、锚 {9,9} → p9
do
    local m = match(S3ONLY, { episode = 9, anchor_page = 9, anchor_episode = 9 })
    check("match 单季 第9集 → p9", m and m.page == 9)
end

-- 6b. 单季、本地 (nil,15)、锚 {14,14}：无候选、delta 越界 → nil
do
    local m = match(S3ONLY, { episode = 15, anchor_page = 14, anchor_episode = 14 })
    check("match 单季 第15集 越界 → nil", m == nil)
end

-- 7. 合集、本地 (nil,15)、锚 {63,14}：裸15/【S2】15 并列、delta 64 越界 → nil
do
    local m = match(FRANCHISE, { episode = 15, anchor_page = 63, anchor_episode = 14 })
    check("match 合集 第15集 歧义 → nil", m == nil)
end

-- 8. 时长歧视：【S3】09 时长 1800（差>300 罚分且吃掉锚点加分）、裸 09 时长吻合 → 裸 p9 胜出
do
    local parts = {}
    for i = 1, 23 do
        parts[#parts + 1] = { page = i, part = string.format("%02d", i), duration = 1430 + i }
    end
    for i = 1, 14 do
        parts[#parts + 1] = { page = 30 + i, part = string.format("【S3】%02d", i), duration = 1800 }
    end
    local m = match(parts, { episode = 9, anchor_page = 39, anchor_episode = 9 })
    check("match 时长歧视 → 裸p9", m and m.page == 9)
end

-- 9. 唯一候选但时长差 400 且非锚点页 → 拒绝（无锚点可退）
do
    local m = match(S3ONLY, { episode = 9, duration = 1835 })
    check("match 唯一候选时长矛盾 → nil", m == nil)
end

-- 9b. 唯一候选时长差 >300 但锚点 delta 可用 → 退回 delta 收下
-- （裸数字投稿 vs 本地不同剪辑版本，时长漂移 ~570s 的场景）
do
    local parts = {
        { page = 1, part = "1", duration = 2012 },
        { page = 2, part = "2", duration = 2012 },
        { page = 3, part = "3", duration = 2012 },
    }
    local m = match(parts, { episode = 2, duration = 1440,
        anchor_page = 1, anchor_episode = 1 })
    check("match 单候选时长矛盾退回delta → p2", m and m.page == 2 and m.via == "delta")
end

-- 9c. delta 落点为 MAD 类短分P（234s vs 本地 2012s）→ 时长硬门 600 拒绝
do
    local parts = {
        { page = 19, part = "19", duration = 2012 },
        { page = 20, part = "『MAD』双子星", duration = 234 },
    }
    local m = match(parts, { episode = 20, duration = 2012,
        anchor_page = 19, anchor_episode = 19 })
    check("match delta落点MAD被时长门拦截 → nil", m == nil)
end

-- 10. 全不可解析标题（上集/下集/…），锚 {5,5}，第 7 集 → 纯 delta → p7
do
    local parts = {
        { page = 1, part = "上集", duration = 1435 },
        { page = 2, part = "下集", duration = 1435 },
        { page = 3, part = "PV", duration = 1435 },
        { page = 4, part = "Part 1", duration = 1435 },
        { page = 5, part = "第一话", duration = 1435 },
        { page = 6, part = "第二话", duration = 1435 },
        { page = 7, part = "第三话", duration = 1435 },
        { page = 8, part = "第四话", duration = 1435 },
    }
    -- 注意："第一话"等中文数字不可解析，故候选为空，delta 兜底
    local m = match(parts, { episode = 7, anchor_page = 5, anchor_episode = 5 })
    check("match 不可解析标题 纯delta → p7", m and m.page == 7 and m.via == "delta")
end

-- 11. 同集重放：当前集 == 锚点集 → 返回锚点页
do
    local m = match(FRANCHISE, { episode = 9, anchor_page = 58, anchor_episode = 9 })
    check("match 同集重放 → 锚点页", m and m.page == 58)
end

-- 12. 双裸 9 无锚、时长相同 → 真歧义 → nil
do
    local parts = {
        { page = 1, part = "9", duration = 1435 },
        { page = 2, part = "9", duration = 1435 },
    }
    local m = match(parts, { episode = 9 })
    check("match 双裸同集无锚 → nil", m == nil)
end

-- 13. episode=nil → nil
do
    local m = match(FRANCHISE, { episode = nil, anchor_page = 58, anchor_episode = 9 })
    check("match episode为nil → nil", m == nil)
end

-- ---------- 锚点相对编号校准（合并多季合集）----------
-- 合并季合集的分P常按合集内序号编号（"1".."19"），本地文件名用全局集数
-- （"78".."85"），两套体系差常量偏移；锚点 (page, episode) 是对齐基准

-- 14. 用户实例：ep80（本地全局集数），锚 {13,79}，时长 2431 → delta p14
do
    local m = match(MERGED, { episode = 80, anchor_page = 13, anchor_episode = 79, duration = 2431 })
    check("match 合并季全局编号 ep80 → p14", m and m.page == 14 and m.via == "delta")
end

-- 14b. 同集重放：ep79，锚 {13,79} → delta p13（旧守卫 pe 13≠79 同样误杀重放）
do
    local m = match(MERGED, { episode = 79, anchor_page = 13, anchor_episode = 79, duration = 2752 })
    check("match 合并季全局编号 重放ep79 → p13", m and m.page == 13 and m.via == "delta")
end

-- 14c. 回退一集：ep78 → p12
do
    local m = match(MERGED, { episode = 78, anchor_page = 13, anchor_episode = 79, duration = 2344 })
    check("match 合并季全局编号 ep78 → p12", m and m.page == 12)
end

-- 14d. 季末：ep85（夺还篇最后一集）→ p19
do
    local m = match(MERGED, { episode = 85, anchor_page = 13, anchor_episode = 79, duration = 3072 })
    check("match 合并季全局编号 ep85 → p19", m and m.page == 19)
end

-- 14e. 越界：ep86 → delta 落点 p20 是 MAD，时长门拦截 → nil
do
    local m = match(MERGED, { episode = 86, anchor_page = 13, anchor_episode = 79, duration = 3072 })
    check("match 合并季全局编号 ep86 MAD拦截 → nil", m == nil)
end

-- 15. 锚点滚动链：上一集匹配成功后锚点回写为 {14,80}，再切 ep81 → p15
do
    local m = match(MERGED, { episode = 81, anchor_page = 14, anchor_episode = 80, duration = 2432 })
    check("match 合并季 锚点滚动 ep81 → p15", m and m.page == 15)
end

-- 16. 缺集保护：合集缺第3集（标题 1,2,4,5），锚 {1,1}，ep3 → 落点 pe=4 ≠ expected 3 → nil
do
    local parts = {
        { page = 1, part = "1", duration = 1435 },
        { page = 2, part = "2", duration = 1435 },
        { page = 3, part = "4", duration = 1435 },
        { page = 4, part = "5", duration = 1435 },
    }
    local m = match(parts, { episode = 3, anchor_page = 1, anchor_episode = 1 })
    check("match 缺集 编号矛盾拒绝 → nil", m == nil)
end

-- 17. pe0 未知保守分支：锚点分P标题不可解析（"上集"），退回与本地集数直接比较
do
    local parts = {
        { page = 1, part = "上集", duration = 1435 },
        { page = 2, part = "5", duration = 1435 },
        { page = 3, part = "6", duration = 1435 },
    }
    local m = match(parts, { episode = 2, anchor_page = 1, anchor_episode = 1 })
    check("match pe0未知 保守拒绝 → nil", m == nil)
end

-- 18. 单候选数字巧合仲裁：合并季合集两季时长接近（标准集 ~24min），本地按季内
--     编号（"02"），唯一标题候选 p2（"2"）是 S3 第2集的巧合命中 → 仲裁取 delta p14
do
    local parts = {}
    for i = 1, 19 do
        parts[#parts + 1] = { page = i, part = tostring(i), duration = 1435 }
    end
    local m = match(parts, { episode = 2, anchor_page = 13, anchor_episode = 1 })
    check("match 合并季 季内编号 巧合候选仲裁 → p14", m and m.page == 14 and m.via == "delta")
end

-- 19. 偏移为 0（pe0 == 锚点集数）时单候选不受仲裁影响 → 仍走 title
do
    local m = match(S3ONLY, { episode = 9, anchor_page = 9, anchor_episode = 9 })
    check("match 偏移0 单候选不仲裁 → p9 title", m and m.page == 9 and m.via == "title")
end

-- 20. 带季标题 + 全局本地编号：【S3】01..11 + 【S4】01..08，锚 {13,79}（pe0=2）→ p14
do
    local parts = {}
    for i = 1, 11 do
        parts[#parts + 1] = { page = i, part = string.format("【S3】%02d", i), duration = 2012 }
    end
    for i = 1, 8 do
        parts[#parts + 1] = { page = 11 + i, part = string.format("【S4】%02d", i), duration = 2431 }
    end
    local m = match(parts, { episode = 80, anchor_page = 13, anchor_episode = 79, duration = 2431 })
    check("match 带季标题+全局编号 ep80 → p14", m and m.page == 14)
end

-- 21. 反向偏移：合集全局标题（第67话..第85话，p13=第79话）+ 本地季内编号，
--     锚 {13,2}（pe0=79），ep3 → delta p14（第80话）
do
    local parts = {}
    for i = 67, 85 do
        parts[#parts + 1] = { page = i - 66, part = string.format("第%d话", i), duration = 2431 }
    end
    local m = match(parts, { episode = 3, anchor_page = 13, anchor_episode = 2, duration = 2431 })
    check("match 合集全局标题+季内编号 ep3 → p14", m and m.page == 14)
end

-- 22. 仲裁回退：delta 落点缺失（MERGED 去掉 p14）→ 仍收标题候选 p2
do
    local m = match(MERGED_GAP, { episode = 2, anchor_page = 13, anchor_episode = 1, duration = 2012 })
    check("match 仲裁delta落点缺失回退 → p2 title", m and m.page == 2 and m.via == "title")
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
mp.commandv("quit", failures > 0 and "1" or "0")
