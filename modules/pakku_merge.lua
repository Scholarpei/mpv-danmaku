-- pakku 式弹幕相似度合并引擎
-- 算法参考并行为复刻自 pakku.js (https://github.com/xmcp/pakku.js, GPLv3, by xmcp)
-- 本模块为独立实现的纯 Lua 版本，未复制任何 pakku 源码或数据；无 mp.* 依赖以便单元测试
--
-- 流程：文本归一化 → 滑动时间窗聚类
-- 相似判定四通道（首中即停）：完全相同 / 字符多重集距离 / 拼音多重集距离 / 环形二元组余弦
-- 簇输出：第 20 百分位成员为代表项，最高频归一化文本为显示文本，模式提升（底部>顶部>滚动）

local UTF8_PATTERN = '[%z\1-\127\194-\244][\128-\191]*'

-- pakku 默认常量（pakkujs/background/config.ts）
local MAX_DIST = 5                -- 字符/拼音多重集距离阈值（pakku「中等」档）
local MAX_COSINE = 45             -- 环形二元组 cos² 阈值（百分比，pakku「中等」档）
local REPRESENTATIVE_PERCENT = 20 -- 代表项取簇内第 N 百分位成员
local HASH_MOD = 1007             -- 二元组哈希系数
-- 性能护栏：每条弹幕至多回看最近 N 个活跃簇。偏离 pakku（pakku 用 2^19-3），
-- 防止同窗口内大量唯一文本的病理性弹幕墙拖慢加载
local MAX_CANDIDATES = 256

-- mp.msg 可选（纯 Lua 测试环境下静默）
local msg = { verbose = function() end, warn = function() end }
pcall(function() msg = require("mp.msg") end)

local function char_to_cp(ch)
    local b1 = string.byte(ch, 1)
    if b1 < 0x80 then
        return b1
    elseif b1 < 0xE0 then
        return (b1 % 0x20) * 0x40 + (string.byte(ch, 2) % 0x40)
    elseif b1 < 0xF0 then
        return (b1 % 0x10) * 0x1000 + (string.byte(ch, 2) % 0x40) * 0x40 + (string.byte(ch, 3) % 0x40)
    else
        return (b1 % 0x08) * 0x40000 + (string.byte(ch, 2) % 0x40) * 0x1000
            + (string.byte(ch, 3) % 0x40) * 0x40 + (string.byte(ch, 4) % 0x40)
    end
end

local function cp_to_char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    else
        return string.char(0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
end

local function utf8_len_of(s)
    local n = 0
    for _ in s:gmatch(UTF8_PATTERN) do n = n + 1 end
    return n
end

-- 尾部标点集合（pakku ENDING_CHARS）
local ENDING_CHARS = {}
do
    local ending = ".。,，/?？!！…~～@^、+=-_♂♀ "
    for ch in ending:gmatch(UTF8_PATTERN) do ENDING_CHARS[ch] = true end
end

-- 全半角折叠表。pakku 故意把少数常用标点的「规范形」定为全角（! ? ; : , . → ！？；：，．），
-- 使半角/全角写法都能互相合并 —— 这是有意行为，勿「修正」
local WIDTH_TABLE = {}
do
    for cp = 0x21, 0x7E do
        local ascii = string.char(cp)
        local full = cp_to_char(cp + 0xFEE0)
        WIDTH_TABLE[ascii] = ascii
        WIDTH_TABLE[full] = ascii
    end
    local fullwidth_canon = {
        ["!"] = "！", ["?"] = "？", [";"] = "；",
        [":"] = "：", [","] = "，", ["."] = "．",
    }
    for ascii, full in pairs(fullwidth_canon) do
        WIDTH_TABLE[ascii] = full
        WIDTH_TABLE[full] = full
    end
    WIDTH_TABLE["　"] = " " -- U+3000 全角空格
end

-- CJK 判定（pakku TRIM_CJK_SPACE_RE：U+3000-U+9FFF / U+FF00-U+FFEF）
local function is_cjk_char(ch)
    local cp = char_to_cp(ch)
    return (cp >= 0x3000 and cp <= 0x9FFF) or (cp >= 0xFF00 and cp <= 0xFFEF)
end

-- 解析套路规则配置串："^2333+=>23333|^666+=>66666"
-- 多条规则用 | 分隔，pattern=>replacement（Lua pattern 语法），结果按原文缓存
local forcelist_cache = {}
local function parse_forcelist(str)
    if not str or str == "" then return {} end
    local cached = forcelist_cache[str]
    if cached then return cached end
    local rules = {}
    for rule_str in str:gmatch("[^|]+") do
        local pat, repl = rule_str:match("^(.-)=>(.*)$")
        if pat and pat ~= "" then
            rules[#rules + 1] = { pat, repl or "" }
        end
    end
    forcelist_cache[str] = rules
    return rules
end

-- 归一化（pakku detaolu）：去控制字符/首尾空白 → 去尾部标点 → 全半角折叠
-- → 空格折叠 + CJK 间单空格删除 → 套路规则重写
local function normalize(text, forcelist)
    if not text or text == "" then return "" end
    text = text:gsub("[\r\n\t]", "")

    local chars = {}
    for ch in text:gmatch(UTF8_PATTERN) do chars[#chars + 1] = ch end

    -- 去首尾空白（含全角空格）
    while #chars > 0 and (chars[1] == " " or chars[1] == "　") do table.remove(chars, 1) end
    while #chars > 0 and (chars[#chars] == " " or chars[#chars] == "　") do chars[#chars] = nil end

    -- 去尾部标点；若整条都是标点则保留原样，避免空串互相误合并
    local i = #chars
    while i > 0 and ENDING_CHARS[chars[i]] do i = i - 1 end
    if i > 0 then
        for j = #chars, i + 1, -1 do chars[j] = nil end
    end

    -- 全半角折叠
    for j = 1, #chars do
        chars[j] = WIDTH_TABLE[chars[j]] or chars[j]
    end

    -- 连续空格折叠为单个 ASCII 空格
    local collapsed = {}
    for j = 1, #chars do
        local ch = chars[j]
        if ch == " " or ch == "　" then
            if collapsed[#collapsed] ~= " " then collapsed[#collapsed + 1] = " " end
        else
            collapsed[#collapsed + 1] = ch
        end
    end

    -- 两侧均为 CJK 字符的单空格删除（pakku：哭 死 → 哭死）
    chars = {}
    for j = 1, #collapsed do
        local ch = collapsed[j]
        if ch == " " and j > 1 and j < #collapsed
            and is_cjk_char(collapsed[j - 1]) and is_cjk_char(collapsed[j + 1]) then
            -- 跳过
        else
            chars[#chars + 1] = ch
        end
    end

    local norm = table.concat(chars)
    -- 套路规则顺序应用（pakku continue-on-match：命中后继续套用后续规则）
    for _, rule in ipairs(forcelist or {}) do
        norm = norm:gsub(rule[1], rule[2])
    end
    return norm
end

-- 拼音字典（dicts/pinyin_chars.lua 由 tools/gen_pinyin_dict.py 生成，缺失时自动禁用；
-- dicts/pinyin_chars_ext.lua 为 GBK 扩展字补充表（咲、凪、雫等，约 14k 字），
-- 存在时叠加进主表，缺失仅收窄覆盖面不影响主表）
local pinyin_dict = nil
local pinyin_checked = false
local function pinyin_available()
    if not pinyin_checked then
        pinyin_checked = true
        local ok, dict = pcall(require, "dicts/pinyin_chars")
        if ok and type(dict) == "table" then
            pinyin_dict = dict
            local ok_ext, ext = pcall(require, "dicts/pinyin_chars_ext")
            if ok_ext and type(ext) == "table" then
                for ch, readings in pairs(ext) do
                    if pinyin_dict[ch] == nil then pinyin_dict[ch] = readings end
                end
            end
        else
            msg.warn("未找到 dicts/pinyin_chars.lua，拼音谐音合并自动禁用")
        end
    end
    return pinyin_dict ~= nil
end

-- 每条弹幕的预计算缓存；拼音/二元组直方图懒构建
local function mk_record(d, forcelist)
    local norm = normalize(d.text, forcelist)
    local rec = { obj = d, norm = norm, len = 0, h_char = {}, py = nil, py_len = 0, gram = nil }
    local h = rec.h_char
    local n = 0
    for ch in norm:gmatch(UTF8_PATTERN) do
        local cp = char_to_cp(ch)
        h[cp] = (h[cp] or 0) + 1
        n = n + 1
    end
    rec.len = n
    return rec
end

-- 拼音音节直方图：多音字的所有读音均计入（pakku 行为，音节总数同时膨胀，门控两侧一致）
local function py_hist(rec)
    local h = rec.py
    if h then return h, rec.py_len end
    h = {}
    local len = 0
    for ch in rec.norm:gmatch(UTF8_PATTERN) do
        local readings = pinyin_dict and pinyin_dict[ch]
        if readings then
            for syll in readings:gmatch("[^,]+") do
                h[syll] = (h[syll] or 0) + 1
                len = len + 1
            end
        else
            local low = ch:lower() -- ASCII 字母转小写，其余原样
            h[low] = (h[low] or 0) + 1
            len = len + 1
        end
    end
    rec.py = h
    rec.py_len = len
    return h, len
end

-- 环形二元组直方图：含首尾环绕配对（最后一字符 × 第一字符），key = c1*1007 + c2
local function gram_hist(rec)
    local h = rec.gram
    if h then return h end
    h = {}
    local prev, first = nil, nil
    for ch in rec.norm:gmatch(UTF8_PATTERN) do
        local cp = char_to_cp(ch)
        if not first then first = cp end
        if prev then
            local key = prev * HASH_MOD + cp
            h[key] = (h[key] or 0) + 1
        end
        prev = cp
    end
    if first and prev then
        -- 环绕配对（单字符串即 c×c，与 pakku 一致）
        local key = prev * HASH_MOD + first
        h[key] = (h[key] or 0) + 1
    end
    rec.gram = h
    return h
end

-- 多重集 L1 距离：Σ|count_a(k) − count_b(k)|
local function hist_l1(h1, h2)
    local dist = 0
    for k, v in pairs(h1) do
        local w = h2[k]
        if w then
            local d = v - w
            dist = dist + (d > 0 and d or -d)
        else
            dist = dist + v
        end
    end
    for k, v in pairs(h2) do
        if not h1[k] then dist = dist + v end
    end
    return dist
end

-- 距离通道判定：长度差门控 + pakku 短串按比例收紧（len_sum < 2*max_dist 时
-- 要求 dist < max_dist * len_sum / (2*max_dist)，整数交叉相乘避免浮点）
local function dist_pass(len_a, len_b, dist, max_dist)
    local diff = len_a - len_b
    if diff < 0 then diff = -diff end
    if diff > max_dist then return false end
    local len_sum = len_a + len_b
    if len_sum < 2 * max_dist then
        return dist * 2 * max_dist < max_dist * len_sum
    end
    return dist <= max_dist
end

-- 相似判定（pakku 通道顺序：相同 → 多重集 → 拼音 → 余弦，首中即停）。
-- cfg.max_dist / cfg.max_cosine 可覆盖模块默认阈值（相似度强度档位）；不传时行为与 pakku 默认一致
local function similar(a, b, cfg)
    cfg = cfg or {}
    local max_dist = cfg.max_dist or MAX_DIST
    local max_cosine = cfg.max_cosine or MAX_COSINE
    if a.len == 0 or b.len == 0 then return false end
    if not cfg.cross_mode and a.obj.type ~= b.obj.type then return false end

    -- 通道 1：归一化后完全相同
    if a.norm == b.norm then return true end

    -- 通道 2：字符多重集 L1 距离（pakku 的「编辑距离」实为字符袋距离，非 Levenshtein）
    local dist = hist_l1(a.h_char, b.h_char)
    if dist_pass(a.len, b.len, dist, max_dist) then return true end

    -- 通道 3：拼音多重集距离（谐音合并）
    if cfg.use_pinyin and pinyin_dict then
        local pa, la = py_hist(a)
        local pb, lb = py_hist(b)
        if dist_pass(la, lb, hist_l1(pa, pb), max_dist) then return true end
    end

    -- 通道 4：环形二元组 cos² ≥ max_cosine；无公共字符（dist ≥ len_sum）时必为 0，跳过
    if dist >= a.len + b.len then return false end
    local ga, gb = gram_hist(a), gram_hist(b)
    local dot, na, nb = 0, 0, 0
    for k, v in pairs(ga) do
        na = na + v * v
        local w = gb[k]
        if w then dot = dot + v * w end
    end
    for _, v in pairs(gb) do nb = nb + v * v end
    if dot == 0 or na == 0 or nb == 0 then return false end
    return 100 * dot * dot >= max_cosine * na * nb
end

-- 主入口：danmakus 须按 time 升序（流水线上游的堆归并保证），返回新的升序列表
local function merge(danmakus, cfg)
    cfg = cfg or {}
    if not danmakus or #danmakus < 2 then return danmakus end
    local window = cfg.window or 30
    local cross_mode = cfg.cross_mode ~= false
    local forcelist = cfg.forcelist or {}

    local active, active_start = {}, 1 -- 活跃簇列表（滑动窗口）
    local exact_map = {}               -- 归一化文本 → 簇（完全相同快路径）
    local result = {}

    local function emit(cluster)
        local peers = cluster.records
        local n = #peers
        -- 代表项：按时间第 20 百分位成员（pakku REPRESENTATIVE_PERCENT，0 基转 1 基）
        local ridx = math.min(math.floor(n * REPRESENTATIVE_PERCENT / 100), n - 1) + 1
        local rep = peers[ridx].obj

        -- 模式提升：底部(4) > 顶部(5) > 其余取代表项类型
        local mode = rep.type
        for i = 1, n do
            if peers[i].obj.type == 4 then mode = 4 break end
        end
        if mode ~= 4 then
            for i = 1, n do
                if peers[i].obj.type == 5 then mode = 5 break end
            end
        end

        -- 显示文本：簇内最高频归一化文本（pakku 行为，多条簇显示归一化结果），
        -- 并列取中位长度；单条簇保持原文直通（pakku FORCELIST_APPLY_SINGULAR=false）
        local text = peers[1].obj.text
        if n > 1 then
            local best_cnt, tied = 0, {}
            for norm, cnt in pairs(cluster.text_counts) do
                if cnt > best_cnt then
                    best_cnt, tied = cnt, { norm }
                elseif cnt == best_cnt then
                    tied[#tied + 1] = norm
                end
            end
            table.sort(tied, function(x, y)
                return utf8_len_of(x) < utf8_len_of(y)
            end)
            text = tied[math.ceil(#tied / 2)]
        end

        local out = {
            time = rep.time, orig_time = rep.orig_time, type = mode,
            size = rep.size, color = rep.color, text = text,
            source = rep.source, merge_count = n,
        }
        -- ×N 后缀沿用插件原合并器约定（count>2 或成员时间不全等时附加）
        if n > 2 or not cluster.same_time then
            out.text = text .. string.format("x%d", n)
            out.merged_x_suffix = true -- 后缀由引擎生成，供 parse 侧样式化（避免误样式化用户原文的 x数字 结尾）
        end
        result[#result + 1] = out
    end

    for _, d in ipairs(danmakus) do
        local rec = mk_record(d, forcelist)
        local t = d.time or 0

        -- 窗口自簇首成员起算：簇首过期即 finalize（pakku 滑动窗口语义）
        while active[active_start] do
            local c = active[active_start]
            if t - c.head_time > window then
                if exact_map[c.key] == c then exact_map[c.key] = nil end
                emit(c)
                active_start = active_start + 1
            else
                break
            end
        end

        -- 完全相同快路径（跨模式关闭时哈希键带上类型）
        local key = rec.norm
        if not cross_mode then key = key .. "#" .. tostring(d.type or "") end
        local c = exact_map[key]

        if not c then
            -- 线性扫描活跃簇（最早优先，至多回看 MAX_CANDIDATES 个），与簇首成员比较
            local n_active = #active
            local first = n_active - MAX_CANDIDATES + 1
            if first < active_start then first = active_start end
            for i = first, n_active do
                if similar(rec, active[i].records[1], cfg) then
                    c = active[i]
                    break
                end
            end
        end

        if c then
            local peers = c.records
            peers[#peers + 1] = rec
            c.text_counts[rec.norm] = (c.text_counts[rec.norm] or 0) + 1
            if t ~= c.head_time then c.same_time = false end
        else
            c = {
                head_time = t, records = { rec },
                text_counts = { [rec.norm] = 1 },
                key = key, same_time = true,
            }
            active[#active + 1] = c
            exact_map[key] = c
        end
    end

    for i = active_start, #active do emit(active[i]) end

    -- 代表项时间可能晚于后续簇，输出必须重排以维持升序（render 二分与密度窗口依赖）
    table.sort(result, function(x, y) return x.time < y.time end)
    return result
end

return {
    MAX_DIST = MAX_DIST,
    MAX_COSINE = MAX_COSINE,
    merge = merge,
    normalize = normalize,
    parse_forcelist = parse_forcelist,
    pinyin_available = pinyin_available,
    similar = similar,
}
