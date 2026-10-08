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

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
mp.commandv("quit", failures > 0 and "1" or "0")
