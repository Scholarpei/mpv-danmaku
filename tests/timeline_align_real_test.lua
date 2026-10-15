-- 跨源时间轴对齐·真实多源场景测试：用实抓弹幕 fixture（同一集三个平台）验证对齐行为
-- fixture 来源（2026-10-11 实抓，相反的你和我 / Seihantai na Kimi to Boku 2026 S01E06）：
--   seihantai_ddp_e06.json  弹弹play镜像 comment API episodeId=190100006（5249 条，含 withRelated 聚合）
--   seihantai_baha_e06.json 巴哈 danmu.php App API videoSn=47472（1210 条，繁体，time 单位 0.1s）
--   seihantai_ako_e06.json  animeko danmaku API episodeId=1587649（76 条，playTime 单位 ms）
--   seihantai_bili_e09.xml / seihantai_ddp_e09.json（S01E09）：bilibili 官方番剧片头差异场景
-- 实测要点：巴哈↔弹弹池归一化文本重合仅 552/1210≈46%（两岸社区弹幕本就不同），
--   但重合部分 391/552=71% 集中投 0 秒（本集两边时间轴天然一致）；据此把默认门槛
--   timeline_align_min_match 校准为 0.3（danmu_api 的 0.8 面向大陆源池，会整源跳过巴哈）
-- 运行：mpv.com --no-config --idle=once --script=<本文件>

local ROOT = "D:/software/mpv-lazy/portable_config/scripts/uosc_danmaku"
package.path = ROOT .. "/?.lua;" .. package.path
local utils = require("mp.utils")
show_message = function() end -- parse 空弹幕分支/导出提示会调 OSD，测试环境打桩
require("modules/options")
require("modules/utils")
require("modules/parse")
local talign = require("modules/timeline_align")
local aparse = require("modules/animeko_parse")
local t2s = require("dicts/t2s_chars")

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

local DDP_URL = "https://danmaku-api.152468.xyz/api/v2/comment/190100006?withRelated=true&chConvert=0"
local BAHA_URL = "https://ani.gamer.com.tw/animeVideo.php?sn=47472"
local AKO_URL = "https://api.animeko.org/episode/1587649"

local function read_fixture(name)
    local f = io.open(ROOT .. "/tests/fixtures/" .. name, "r")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end

-- dandanplay：镜像 apis/dandanplay.lua save_danmaku_to_list 的字段序（p = time,type,color,uid）
local function load_ddp()
    local d = utils.parse_json(read_fixture("seihantai_ddp_e06.json"))
    local out = {}
    for _, cm in ipairs(d.comments or {}) do
        local fields = {}
        local i = 1
        for val in (cm.p or ""):gmatch("([^,]+)") do
            fields[i] = tonumber(val)
            i = i + 1
        end
        out[#out + 1] = { time = fields[1], type = fields[2], color = fields[3] or 0xFFFFFF,
            size = 25, text = cm.m or "" }
    end
    return out
end

-- 巴哈：镜像 sites/bahamut.lua save_comments（time/10、hex 色、position→mode），
-- 产出 {c,m} 数组后走真实 parse_json_danmaku（与插件 save_danmaku_json 同路径）
local function load_baha()
    local d = utils.parse_json(read_fixture("seihantai_baha_e06.json"))
    local arr = {}
    for _, cm in ipairs((d.data and d.data.danmu) or {}) do
        local mode = cm.position == 0 and 1 or (cm.position == 1 and 4 or 5)
        arr[#arr + 1] = {
            c = string.format("%s,%s,%s,25", tonumber(cm.time) / 10, hex_to_int_color(cm.color), mode),
            m = cm.text,
        }
    end
    return parse_json_danmaku(utils.format_json(arr))
end

-- animeko：真实模块解析（modules/animeko_parse.lua parse_danmaku_list）
local function load_ako()
    local out = {}
    for _, c in ipairs(aparse.parse_danmaku_list(utils.parse_json(read_fixture("seihantai_ako_e06.json")))) do
        out[#out + 1] = { time = c.time, type = c.mode, color = c.color, size = 25, text = c.text }
    end
    return out
end

-- 直调 talign.compute 用的 transform：镜像 parse.lua 局部 ch_convert（同 dicts/t2s_chars 表；
-- 管线内部走 compute_timeline_alignment 的真实 transform，由 C 节 e2e 覆盖）
local function to_simplified(text)
    if type(text) ~= "string" or text == "" then return text end
    return text:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c) return t2s[c] or c end)
end

local ddp, baha, ako = load_ddp(), load_baha(), load_ako()

-- ============ A. 真实数据 · 纯模块（确定性参考值，fixture 固定即稳定） ============

check("A0 实抓条数", #ddp == 5249 and #baha == 1210 and #ako == 76)

local function compute_real(opts)
    return talign.compute({
        { url = DDP_URL, provider = "ddp", entries = ddp },
        { url = BAHA_URL, provider = "巴哈姆特", entries = baha },
        { url = AKO_URL, provider = "animeko", entries = ako },
    }, opts)
end

-- Relative relationships are independent of a video's assumed correctness.
local result=compute_real({transform=to_simplified})
check('A1 real common pool is connected',result.members[BAHA_URL]==result.members[DDP_URL])
check('A1 sparse animeko remains independent',result.members[AKO_URL]~=result.members[DDP_URL])
check('A1 real zero offset preserved',talign.coordinate(result,DDP_URL,590)==590)
local strict=compute_real({transform=to_simplified,min_match_ratio=0.8})
check('A2 strict overlap rejects weak relation',strict.members[BAHA_URL]~=strict.members[DDP_URL])

-- ============ B. 真实数据 + 模拟片头差异（巴哈整体晚 90 秒）============

local baha_plus90 = {}
for i, c in ipairs(baha) do
    baha_plus90[i] = { time = c.time + 90, type = c.type, color = c.color, size = c.size, text = c.text }
end

local shifted = talign.compute({
    { url = DDP_URL, provider = "ddp", entries = ddp },
    { url = BAHA_URL, provider = "巴哈姆特", entries = baha_plus90 },
}, { transform = to_simplified })
check('B1 real shifted sources converge relatively',
    talign.coordinate(shifted,BAHA_URL,680)==talign.coordinate(shifted,DDP_URL,590))

-- ============ C. 真实数据 e2e：管线收集期应用平移，共享文本双源收敛 ============

options.density_control = "off" -- 断言存在性/时间，规避智能密度随机丢弃的不确定性（合并保持默认开）

local function build_sources(baha_data)
    return {
        [DDP_URL] = { from = "api_server", provider = "ddp", data = ddp },
        [BAHA_URL] = { from = "user_custom", provider = "巴哈姆特", data = baha_data },
        [AKO_URL] = { from = "user_custom", provider = "animeko", data = ako },
    }
end

-- 收敛锚点（实抓双源同文本同时间戳）：kksk@590.00 / XDD@486.60 / Richt@739.40
local function kksk_events()
    local evs = {}
    for _, ev in ipairs(COMMENTS) do
        if ev.text and ev.text:lower():find("kksk", 1, true) then evs[#evs + 1] = ev end
    end
    return evs
end

-- C1 开启对齐（默认）：巴哈+90s 被校正回基准时间轴
DANMAKU = { sources = build_sources(baha_plus90), count = 3 }
COMMENTS = {}
require('modules/timeline').prepare()
require('modules/timeline').anchor(DDP_URL,590,590,'group')
convert_danmaku_to_ass_events(true)
check("C1a 相对组坐标不冒充本地校准",
    DANMAKU.sources[BAHA_URL].align_shift == 0
        and DANMAKU.sources[DDP_URL].align_shift == 90
        and DANMAKU.sources[AKO_URL].align_shift == 0)
do
    local evs = kksk_events()
    local at_590 = false
    for _, ev in ipairs(evs) do
        if math.floor(ev.start_time + 0.5) == 590 then at_590 = true end
    end
    check("C1b 双源 kksk 收敛到 590s", at_590)
end

-- C1c/d 收敛断言走 XML 导出路径：真实数据同屏弹幕密集，布局车道不足会静默丢事件
--（get_position_y 返回 nil），而导出无布局/无取整，时间戳原样落盘，是更强的收敛证明。
-- 锚点取双源原文精确一致的 ASCII 文本（kksk@590 / XDD@486.6 / Richt@739.4）；
-- 时间数值比较带容差（+90-90 浮点往返可能有 1ulp 尾差）
do
    local tmp = ROOT .. "/tests/talign_real_tmp_export.xml"
    DANMAKU = { sources = build_sources(baha_plus90), count = 3 }
    require('modules/timeline').prepare()
    require('modules/timeline').anchor(DDP_URL,590,590,'group')
    local ok = convert_danmaku_to_xml(tmp)
    local content = ok and read_file(tmp) or ""
    os.remove(tmp)
    local function line_at(tag, want_time)
        for line in content:gmatch("<d [^\n]*</d>\n") do
            local p = line:match('^<d p="([^,]+),')
            if p and line:lower():find(tag, 1, true)
                and math.abs(tonumber(p) - want_time) <= 0.05 then
                return true
            end
        end
        return false
    end
    check("C1c XDD 收敛到 486.6s", line_at("xdd", 486.6))
    check("C1d Richt 收敛到 739.4s", line_at("richt", 739.4))
end

-- C2 对照：关闭对齐，巴哈 kksk 停在 680s（590+90，未校正）
options.timeline_align = false
DANMAKU = { sources = build_sources(baha_plus90), count = 3 }
COMMENTS = {}
convert_danmaku_to_ass_events(true)
options.timeline_align = true
do
    local at_680 = false
    for _, ev in ipairs(kksk_events()) do
        if math.floor(ev.start_time + 0.5) == 680 then at_680 = true end
    end
    check("C2 关闭对齐时巴哈 kksk 停留 680s", at_680)
end

-- ============ D. 真实数据 · bilibili 官方番剧片头差异（E09 实抓）============
-- 实测结构（BD 内嵌字幕地标验证）：ddp 池与本地 BDrip 正文同轴（OP 歌词逐行弹幕与 BD
-- 字幕全程 -1s 跟踪；池子比 BD 多出的 ~11s 只是 BD 没有的下集预告区），bilibili 官方版
-- 片头加 5s 说明的同时剪掉了更多正文，净效果 = 全片时间戳比基准恒定早 5s（-5s 漂移
-- 1744 票 / 2984 重合，前/后半集 828/917 票全程均匀），对齐按实测方向 +5s 拉回基准——
-- 方向由投票测得，不预设「官方番剧=前面插了说明」的剪辑模型（时长差推方向会得到相反符号）
local BILI09_URL = "https://www.bilibili.com/bangumi/play/ep3270468"

-- ddp：同 load_ddp 的字段序，读 E09 fixture（5384 条，2026-10-11 实抓）
local function load_ddp09()
    local d = utils.parse_json(read_fixture("seihantai_ddp_e09.json"))
    local out = {}
    for _, cm in ipairs(d.comments or {}) do
        local fields = {}
        local i = 1
        for val in (cm.p or ""):gmatch("([^,]+)") do
            fields[i] = tonumber(val)
            i = i + 1
        end
        out[#out + 1] = { time = fields[1], type = fields[2], color = fields[3] or 0xFFFFFF,
            size = 25, text = cm.m or "" }
    end
    return out
end

local function load_bili09()
    return parse_xml_danmaku(read_fixture("seihantai_bili_e09.xml"))
end

-- D1 直调模块：检出 -5s 漂移并整源 +5s 平移（支持跨度 0.2~1403s 全程分布，过门槛）
do
    local ddp09, bili09 = load_ddp09(), load_bili09()
    local r = talign.compute({
        { url = DDP_URL, provider = "ddp", entries = ddp09 },
        { url = BILI09_URL, provider = "bilibili", entries = bili09 },
    }, { transform = to_simplified })
    local diag09 = r.diag[1] -- ddp 为基准，仅 bilibili 一项诊断
    check("D1a E09 实抓条数", #ddp09 == 5384 and #bili09 == 3600)
    check("D1b 两源建立可靠关系", r.members[DDP_URL] == r.members[BILI09_URL])
    check("D1c bilibili 检出 -5s 稳定漂移且覆盖全片",
        diag09 and diag09.drift == -5 and diag09.independent > 1000 and diag09.coverage > 0.9)
    check("D1d 应用 +5s 平移", r.shifts[BILI09_URL] == 5 and diag09.applied)
end

-- D2 管线（chConvert 默认 0=identity）：写回 +5，台词锚点「店长：嗯，偷店里东西？」
--    bilibili 源 701.7s → 收敛到池子同条的 706.7s（关闭对齐则早 5s）
do
    local ddp09 = load_ddp09()
    local sources = {
        [DDP_URL] = { from = "api_server", provider = "ddp", data = ddp09 },
        [BILI09_URL] = { from = "user_custom", provider = "bilibili", data = load_bili09() },
    }
    DANMAKU = { sources = sources, count = 2 }
    COMMENTS = {}
    convert_danmaku_to_ass_events(true)
    check("D2a align_shift 写回（bilibili +5 / ddp 0）",
        DANMAKU.sources[BILI09_URL].align_shift == 5
            and DANMAKU.sources[DDP_URL].align_shift == 0)
    local hit_bili, ddp_anchor = nil, nil
    for _, ev in ipairs(COMMENTS) do
        -- 子串匹配：pakku 合并可能给文本追加 xN 后缀
        if ev.clean_text and ev.clean_text:find("偷店里东西", 1, true)
            and tostring(ev.source) == BILI09_URL then
            hit_bili = ev
        end
    end
    for _, d in ipairs(ddp09) do
        if d.text and d.text:find("偷店里东西", 1, true) then ddp_anchor = d.time end
    end
    check("D2b 池子原始数据同条锚点 706.7s",
        ddp_anchor ~= nil and math.abs(ddp_anchor - 706.7) < 0.05)
    check("D2c bilibili 该条从未对齐 701.7s 收敛到 706.7s",
        hit_bili ~= nil and math.abs(hit_bili.start_time - 706.7) < 0.05)
end

if failures > 0 then
    print(failures .. " FAILURES")
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
