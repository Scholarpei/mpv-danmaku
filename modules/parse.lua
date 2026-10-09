local msg   = require 'mp.msg'
local utils = require 'mp.utils'
local s2t   = require("dicts/s2t_chars")
local t2s   = require("dicts/t2s_chars")
local pakku_merge = require("modules/pakku_merge")
local pakku_density = require("modules/pakku_density")

-- mpv 的 Lua 环境不自动播种随机数（弹幕超限随机丢弃用）
math.randomseed(os.time() + os.clock())

local function ass_escape(text)
    return text:gsub("\\", "\\\\")
               :gsub("{", "\\{")
               :gsub("}", "\\}")
               :gsub("\n", "\\N")
end

-- 构建 per-source 的延迟查询函数
local function make_delay_lookup(source)
    local segments = nil
    local prefix = nil
    if source and source.delay_segments and #source.delay_segments > 0 then
        segments = {}
        for i, v in ipairs(source.delay_segments) do segments[i] = v end
        table.sort(segments, function(a, b) return (a.start or 0) < (b.start or 0) end)
        prefix = {}
        local s = 0
        for i, v in ipairs(segments) do
            s = s + (v.delay or 0)
            prefix[i] = s
        end
    end

    return function(t)
        local segs = segments or {}
        local pre = prefix or {}
        if #segs == 0 then return 0 end
        local idx = binary_search(segs, t, function(s) return (s and s.start) or 0 end)
        local target = idx - 1
        if target < 1 then return 0 end
        return pre[target] or 0
    end
end

local function xml_unescape(str)
    return str:gsub("&quot;", "\"")
              :gsub("&apos;", "'")
              :gsub("&gt;", ">")
              :gsub("&lt;", "<")
              :gsub("&amp;", "&")
end

local function decode_html_entities(text)
    return text:gsub("&#x([%x]+);", function(hex)
        local codepoint = tonumber(hex, 16)
        return unicode_to_utf8(codepoint)
    end):gsub("&#(%d+);", function(dec)
        local codepoint = tonumber(dec, 10)
        return unicode_to_utf8(codepoint)
    end)
end

-- 加载黑名单模式
local function load_blacklist_patterns(filepath)
    local patterns = {}
    if not file_exists(filepath) then
        return patterns
    end
    local file = io.open(filepath, "r")
    if not file then
        msg.error("无法打开黑名单文件: " .. filepath)
        return patterns
    end

    if string.match(filepath, "%.xml$") then
        -- xml文件格式示例
        --<?xml version="1.0" encoding="utf-8"?>
        --<filters>
        --  <item enabled="true">t=卡在</item>
        --  <item enabled="true">t=进度条</item>
        --</filters>
        print("加载黑名单文件: " .. filepath)
        for line in file:lines() do
            local pattern = line:match('<item%s+enabled="true">t=(.-)</item>')
            if pattern then
                print("加载黑名单模式: " .. pattern)
                table.insert(patterns, pattern)
            end
        end
    end

    if string.match(filepath, "%.json$") then
        -- json文件格式示例
        -- [{"type":0,"filter":"开门","opened":true,"id":15628936}
        -- ,{"type":0,"filter":"tony","opened":true,"id":15628939}
        -- ,{"type":1,"filter":"0+.1","opened":true,"id":15628951}]
        local content = read_file(filepath)
        if content then
            local json = utils.parse_json(content)
            if json and type(json) == "table" then
                for _, entry in ipairs(json) do
                    if entry.opened and entry.filter and entry.type == 0 then
                        table.insert(patterns, entry.filter)
                    end
                end
            end
        end
    end

    if string.match(filepath, "%.txt$") then
        -- 文本文件格式示例
        -- 卡在
        -- 进度条
        for line in file:lines() do
            line = line:match("^%s*(.-)%s*$")
            if line ~= "" then
                table.insert(patterns, line)
            end
        end
    end

    file:close()
    return patterns
end

-- 黑名单路径解析：先按 mpv 工作目录（expand-path 原语义），相对路径找不到时回退按脚本目录。
-- 空路径必须短路：绝不能把空值拼进脚本目录而误命中仓库自带的 black.txt
local function resolve_blacklist_path(raw)
    if not raw or raw == "" then return raw end
    -- conf 文件里写的 "路径" mp.options 不剥引号（仅 CLI --script-opts 传参才剥），
    -- 值会带引号字符导致文件永远找不到，此处统一剥掉成对引号
    raw = raw:match('^%s*"(.+)"%s*$') or raw:match("^%s*'(.+)'%s*$") or raw
    local expanded = mp.command_native({ "expand-path", raw })
    local function is_abs(p)
        return p:match("^%a:[/\\]") or p:match("^[/\\]")
    end
    if is_abs(expanded) or file_exists(expanded) then return expanded end
    local script_dir = mp.get_script_directory()
    if script_dir then
        local fallback = utils.join_path(script_dir, expanded)
        if file_exists(fallback) then
            msg.warn("黑名单文件按 mpv 工作目录未找到，已回退到脚本目录: " .. fallback)
            return fallback
        end
    end
    msg.warn("黑名单文件不存在: " .. expanded)
    return expanded
end

local blacklist_file = resolve_blacklist_path(options.blacklist_path)
BLACKLIST_FILE = blacklist_file -- 供菜单「打开黑名单文件位置」使用
local black_patterns = load_blacklist_patterns(blacklist_file)

-- 热重载黑名单（菜单入口调用），返回规则条数
function reload_blacklist()
    black_patterns = load_blacklist_patterns(blacklist_file)
    return #black_patterns
end

-- 供菜单「屏蔽此文本」判断当前规则是否已命中（黑名单规则本身仍是私有局部表）
function is_text_blacklisted(str)
    return is_blacklisted(str, black_patterns)
end

-- 检查字符串是否在黑名单中
function is_blacklisted(str, patterns)
    for _, pattern in ipairs(patterns) do
        local ok, result = pcall(function()
            return str:match(pattern)
        end)

        if ok and result then
            return true, pattern
        elseif not ok then
            -- msg.debug("黑名单规则错误，跳过: " .. pattern .. "，错误信息：" .. result)
        end
    end
    return false
end

-- 简繁转换
local function convert(text, dict)
    return text:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
        return dict[c] or c
    end)
end

local function ch_convert(str)
    local mode = tonumber(options.chConvert) or 0
    if mode == 1 then
        return convert(str, t2s)
    elseif mode == 2 then
        return convert(str, s2t)
    end
    return str
end

local ch_convert_cache = {}
local ch_cache_keys = {}
local ch_cache_max = 5000
local ch_cache_mode = nil

local function ch_convert_cached(text)
    if type(text) ~= "string" or text == "" then return text end
    local mode = tonumber(options.chConvert) or 0
    if mode ~= ch_cache_mode then
        -- 转换模式切换后缓存全部失效（菜单循环 / script-opts 运行时更新都会改 mode），
        -- 两张表必须一起清：只清 cache 会让 FIFO 索引指向已不存在的键
        ch_convert_cache = {}
        ch_cache_keys = {}
        ch_cache_mode = mode
    end
    if mode == 0 then return text end -- 恒等映射不入缓存
    local cached = ch_convert_cache[text]
    if cached ~= nil then return cached end

    local converted = ch_convert(text)
    ch_convert_cache[text] = converted
    ch_cache_keys[#ch_cache_keys+1] = text

    if #ch_cache_keys > ch_cache_max then
        local old_key = table.remove(ch_cache_keys, 1)
        ch_convert_cache[old_key] = nil
    end

    return converted
end

-- 合并重复弹幕
-- 弹幕相似度合并由 modules/pakku_merge.lua 提供（pakku 式四通道，默认开启）

-- 限制每屏弹幕条数
local function limit_danmaku(danmakus, limit)
    if not limit or limit <= 0 then
        return danmakus
    end

    local window = {}
    for _, d in ipairs(danmakus) do
        for i = #window, 1, -1 do
            if window[i].end_time <= d.start_time then
                table.remove(window, i)
            end
        end

        if #window < limit then
            table.insert(window, d)
        else
            -- 超限随机丢弃（B 站行为）：随机选取窗口内一条弹幕丢弃，替换为新弹幕
            local victim = math.random(#window)
            window[victim].drop = true
            window[victim] = d
        end
    end

    local result = {}
    for _, d in ipairs(danmakus) do
        if not d.drop then
            table.insert(result, d)
        end
    end
    return result
end

-- 解析 XML 弹幕
function parse_xml_danmaku(xml_string)
    local danmakus = {}
    if not xml_string then
        return danmakus
    end
    -- [^>]* 匹配其他 attributes
    -- %f[^%s] 确保 p= 前面是空白字符
    for p_attr, text in xml_string:gmatch('<d%s+[^>]*%f[^%s]p="([^"]+)"[^>]*>([^<]+)</d>') do
        local params = {}
        local i = 1
        for val in p_attr:gmatch("([^,]+)") do
            params[i] = tonumber(val)
            i = i + 1
        end

        if params[1] and params[2]  and params[3] and params[4] then
            table.insert(danmakus, {
                time = params[1],
                type = params[2] or 1,
                size = params[3] or 25,
                color = params[4] or 0xFFFFFF,
                text = xml_unescape(text)
            })
        end
    end

    table.sort(danmakus, function(a, b) return a.time < b.time end)
    return danmakus
end

-- 解析 JSON 弹幕
function parse_json_danmaku(json_string)
    local danmakus = {}
    if json_string:sub(1, 3) == "\239\187\191" then
        json_string = json_string:sub(4)
    end

    local json = utils.parse_json(json_string)
    if not json or type(json) ~= "table" then
        msg.info("JSON 解析失败")
        return danmakus
    end

    for _, entry in ipairs(json) do
        local c = entry.c
        local text = entry.m or ""
        if type(c) == "string" then
            local params = {}
            local i = 1
            for val in c:gmatch("([^,]+)") do
                params[i] = tonumber(val)
                i = i + 1
            end

            if params[1] and params[2] and params[3] and params[4] then
                table.insert(danmakus, {
                    time = params[1],
                    color = params[2] or 0xFFFFFF,
                    type = params[3] or 1,
                    size = params[4] or 25,
                    text = text
                })
            end
        end
    end

    table.sort(danmakus, function(a, b) return a.time < b.time end)
    return danmakus
end

-- 解析弹幕文件
function parse_danmaku_file(danmaku_input)
    local danmakus = {}

    if file_exists(danmaku_input) then
        local content = read_file(danmaku_input)
        if content then
            local parsed = {}
            if danmaku_input:match("%.xml$") then
                parsed = parse_xml_danmaku(content)
            elseif danmaku_input:match("%.json$") then
                parsed = parse_json_danmaku(content)
            end

            for _, d in ipairs(parsed) do
                table.insert(danmakus, d)
            end
        else
            msg.info("无法读取文件内容: " .. danmaku_input)
        end
    else
        msg.info("文件不存在: " .. danmaku_input)
    end

    for _, d in ipairs(danmakus) do
        if d.orig_time == nil then d.orig_time = d.time end
    end

    if #danmakus == 0 then
        msg.info("未能解析任何弹幕")
        return nil
    end

    return danmakus
end

--# 弹幕数组与布局算法 (Danmaku Array & Layout Algorithms)
local DanmakuArray = {}
DanmakuArray.__index = DanmakuArray

-- 取整前的对数映射严格递增且严格凹。
-- 取整后的整数字号单调不减，最大字号用于避免合并数量过大时字号失控。
function DanmakuArray.get_merged_font_size(base_size, count, growth, max_size)
    local base = positive_integer(base_size, 1)
    local n = positive_integer(count, 1)
    local scale = positive_integer(growth, 8)
    local maximum = math.max(base, positive_integer(max_size, base))
    local size = base + math.floor(scale * math.log(n) + 0.5)
    return math.min(maximum, size)
end

function DanmakuArray:new(max_y)
    local obj = {
        max_y = positive_integer(max_y, 1),
        danmakus = {},
    }
    setmetatable(obj, self)
    return obj
end

-- 弹幕按出现时间递增的顺序处理。滚动弹幕完全移出屏幕后，或固定弹幕的
-- 显示时间结束后，它便不可能与当前及之后的弹幕碰撞，因此可以安全删除。
function DanmakuArray:remove_expired(now)
    for i = #self.danmakus, 1, -1 do
        if self.danmakus[i].end_time <= now then
            table.remove(self.danmakus, i)
        end
    end
end

local function y_intersects(y1, height1, y2, height2)
    return y1 < y2 + height2 and y2 < y1 + height1
end

local function rolling_danmaku_collides(previous, start_time, velocity)
    local delta_velocity = velocity - previous.velocity
    local delta_x = (start_time - previous.start_time) * previous.velocity - previous.length

    -- delta_x 小于 0 表示旧弹幕尾部尚未进入屏幕，新弹幕出现时会直接重叠。
    if delta_x < 0 then
        return true
    end

    -- 新弹幕速度不大于旧弹幕时，不会缩短已有的 delta_x 间距。
    if delta_velocity <= 0 then
        return false
    end

    -- 比较从新弹幕出现开始的追尾时间与旧弹幕的剩余显示时间；
    -- 只有在旧弹幕离屏前追上它，才会发生碰撞。
    local delta_time = delta_x / delta_velocity
    local remaining_time = previous.end_time - start_time
    return delta_time < remaining_time
end

-- 从 y 轴顶部开始寻找可插入位置。对于每个候选位置，只检查 y 轴区间
-- 与新弹幕相交的已有弹幕；若其中存在碰撞，则跳到碰撞区间下方继续寻找。
local function find_y_from_top(array, height, collides)
    local y = 1
    while y + height - 1 <= array.max_y do
        local next_y = nil
        for _, danmaku in ipairs(array.danmakus) do
            if y_intersects(y, height, danmaku.y, danmaku.height) and collides(danmaku) then
                local below = danmaku.y + danmaku.height
                next_y = next_y and math.max(next_y, below) or below
            end
        end
        if not next_y then return y end
        y = next_y
    end
    return nil
end

-- 从 y 轴顶部开始寻找滚动弹幕的位置，并记录成功插入的弹幕所占区间。
function DanmakuArray:get_position_y(start_time, length, height, resolution_x, duration)
    height = positive_integer(height, 1)
    length = math.max(0, tonumber(length) or 0)
    resolution_x = math.max(1, tonumber(resolution_x) or 1)
    duration = math.max(0.001, tonumber(duration) or 0.001)
    self:remove_expired(start_time)

    local velocity = (length + resolution_x) / duration
    local y = find_y_from_top(self, height, function(previous)
        return rolling_danmaku_collides(previous, start_time, velocity)
    end)
    if not y then return nil end

    self.danmakus[#self.danmakus + 1] = {
        y = y,
        height = height,
        start_time = start_time,
        end_time = start_time + duration,
        length = length,
        velocity = velocity,
    }
    return y
end

-- 顶部固定弹幕自上而下寻找位置，底部固定弹幕则自下而上寻找位置。
function DanmakuArray:get_fixed_y(start_time, height, duration, from_top)
    height = positive_integer(height, 1)
    duration = math.max(0.001, tonumber(duration) or 0.001)
    self:remove_expired(start_time)

    local y
    if from_top then
        y = find_y_from_top(self, height, function() return true end)
    else
        y = self.max_y - height + 1
        while y >= 1 do
            local next_y = nil
            for _, danmaku in ipairs(self.danmakus) do
                if y_intersects(y, height, danmaku.y, danmaku.height) then
                    local above = danmaku.y - height
                    next_y = next_y and math.min(next_y, above) or above
                end
            end
            if not next_y then break end
            y = next_y
        end
        if y < 1 then y = nil end
    end

    if not y then return nil end
    self.danmakus[#self.danmakus + 1] = {
        y = y,
        height = height,
        start_time = start_time,
        end_time = start_time + duration,
    }
    return y
end

-- 将弹幕转换为 XML 格式
function convert_danmaku_to_xml(danmaku_out)
    local danmakus = {}
    for url, source in pairs(DANMAKU.sources) do
        if not source.blocked and source.data then
            local get_cached_delay = make_delay_lookup(source)

            for _, d in ipairs(source.data) do
                local base_time = d.orig_time or d.time
                local adjusted_time = base_time + get_cached_delay(base_time)
                table.insert(danmakus, {
                    orig_time = d.orig_time,
                    time = adjusted_time,
                    type = d.type,
                    size = d.size,
                    color = d.color,
                    text = d.text,
                    source = url,
                })
            end
        end
    end

    if #danmakus == 0 then
        show_message("弹幕内容为空，无法保存", 3)
        msg.verbose("弹幕内容为空，无法保存")
        COMMENTS = {}
        return false
    end

    -- 拼接为 XML 内容
    local xml = { '<?xml version="1.0" encoding="UTF-8"?><i>\n' }
    for _, d in ipairs(danmakus) do
       local time = d.time
       local type = d.type or 1
       local size = d.size or 25
       local color = d.color or 0xFFFFFF
       local text = d.text or ""

       text = text:gsub("&", "&amp;")
                  :gsub("<", "&lt;")
                  :gsub(">", "&gt;")
                  :gsub("\"", "&quot;")
                  :gsub("'", "&apos;")

       table.insert(xml, string.format('<d p="%s,%s,%s,%s">%s</d>\n', time, type, size, color, text))
    end
    table.insert(xml, '</i>')

    -- 写入 XML 文件
    local file = io.open(danmaku_out, "w")
    if not file then
       show_message("无法写入目标 XML 文件", 3)
       msg.info("无法写入目标 XML 文件: " .. danmaku_out)
       return false
    end
    file:write(table.concat(xml))
    file:close()
    show_message("转换 XML 弹幕成功： " .. danmaku_out, 3)
    msg.info("转换 XML 弹幕成功： " .. danmaku_out)
    return true
end

-- pakku 相似度强度档位（max_dist, max_cosine），由 options.merge_similarity 选择。
-- 数值为自拟插值档：medium = pakku 默认 MAX_DIST=5 / MAX_COSINE=45；dist 越大或 cosine 越小合并越激进
local SIM_LEVELS = {
    light = { 2, 60 },
    medium = { 5, 45 },
    strong = { 10, 35 },
}

-- pakku 式智能密度档位（shrink_threshold, drop_threshold，dispval 单位），
-- 由 options.density_level 选择；任一值 <=0 表示禁用对应阶段（pakku 语义）。
-- 标定：1080p/displayarea=0.85 ≈ 18 行 50px 弹幕带；一条 10 字弹幕 dv≈√10≈3.2；
-- 舒适满屏 ≈ 18×3.2 ≈ 58 → medium=50 恰在舒适满屏触发收缩；每档 drop 恒为 shrink 的 2 倍。
-- 档位对 fontsize 修改不敏感（基准同步缩放，clamp 以基准为锚，dv 至多 4×√长度）
local DENSITY_LEVELS = {
    loose  = { 80, 160 },
    medium = { 50, 100 },
    strict = { 30, 60 },
}

function convert_danmaku_to_ass_events(force)
    MERGE_STATS = nil -- 每次重建都重置合并统计（空弹幕提前 return / 未启用合并时防止旧值残留）
    DENSITY_STATS = nil -- 同上，智能密度统计
    BLACKLIST_STATS = nil -- 同上，黑名单过滤统计
    local per_source_lists = {}
    for url, source in pairs(DANMAKU.sources) do
        if not source.blocked and source.data then
            local get_cached_delay = make_delay_lookup(source)

            local list = {}
            for _, d in ipairs(source.data) do
                local base_time = d.orig_time or d.time
                if d.orig_time == nil then d.orig_time = base_time end
                local adjusted_time = base_time + get_cached_delay(base_time)
                table.insert(list, {
                    orig_time = d.orig_time,
                    time = adjusted_time,
                    type = d.type,
                    size = d.size,
                    color = d.color,
                    text = d.text,
                    source = url,
                })
            end

            if #list > 0 then
                table.sort(list, function(a, b) return a.time < b.time end)
                per_source_lists[#per_source_lists + 1] = list
            end
        end
    end

    local danmakus = {}

    local heap = new_min_heap()
    for li = 1, #per_source_lists do
        local lst = per_source_lists[li]
        if lst and #lst > 0 then
            heap.push({ time = lst[1].time, list_idx = li, pos = 1, entry = lst[1] })
        end
    end

    while true do
        local node = heap.pop()
        if not node then break end
        table.insert(danmakus, node.entry)
        local li = node.list_idx
        local next_pos = node.pos + 1
        local lst = per_source_lists[li]
        if lst and lst[next_pos] then
            heap.push({ time = lst[next_pos].time, list_idx = li, pos = next_pos, entry = lst[next_pos] })
        end
    end

    -- 模式转换：顶部/底部弹幕转滚动（pakku 惯例：加 ↑/↓ 前缀保留原模式语义）。
    -- 三态：no/off、yes/on（无差别全转）、auto（仅文本宽度超过 scroll_threshold 的转，
    -- pakku SCROLL_THRESHOLD 语义；阈值 <=0 时 auto 等同 no）
    local function scroll_convert_mode(v)
        if v == "auto" then return "auto"
        elseif v == false or v == nil or v == "no" then return "off"
        else return "on" end -- true / "yes"（conf 布尔写法向后兼容）
    end
    local top_mode = scroll_convert_mode(options.convert_top_to_scroll)
    local bottom_mode = scroll_convert_mode(options.convert_bottom_to_scroll)
    local scroll_threshold = tonumber(options.scroll_threshold) or 1200
    if scroll_threshold <= 0 then top_mode, bottom_mode = "off", "off" end
    if top_mode ~= "off" or bottom_mode ~= "off" then
        local base_fontsize = tonumber(options.fontsize) or 50
        for _, d in ipairs(danmakus) do
            if d.type == 5 and top_mode ~= "off" then
                if top_mode == "on" or get_str_width(d.text or "", base_fontsize) > scroll_threshold then
                    d.type, d.text = 1, "↑" .. (d.text or "") -- 宽度判定用加前缀前的原文
                end
            elseif d.type == 4 and bottom_mode ~= "off" then
                if bottom_mode == "on" or get_str_width(d.text or "", base_fontsize) > scroll_threshold then
                    d.type, d.text = 1, "↓" .. (d.text or "")
                end
            end
        end
    end

    -- pakku 式相似度合并（merge_enabled 总开关；窗口 <=0 或相似度档位 = off 时禁用）
    -- 非法档位值回落 medium，绝不静默禁用；off 显式跳过（不能被 or 兜底吞掉）
    local sim_key = tostring(options.merge_similarity or "medium"):lower()
    local sim_level = nil
    if sim_key ~= "off" then
        sim_level = SIM_LEVELS[sim_key] or SIM_LEVELS.medium
    end
    if options.merge_enabled ~= false
        and sim_level
        and (tonumber(options.merge_tolerance) or 0) > 0 then
        local t_merge = mp.get_time()
        local before = #danmakus
        danmakus = pakku_merge.merge(danmakus, {
            window = tonumber(options.merge_tolerance),
            cross_mode = options.merge_cross_mode ~= false,
            use_pinyin = options.merge_pinyin ~= false and pakku_merge.pinyin_available(),
            forcelist = pakku_merge.parse_forcelist(options.merge_forcelist),
            max_dist = sim_level[1],
            max_cosine = sim_level[2],
        })
        msg.verbose(("pakku 合并: %d -> %d, 耗时 %.0f ms")
            :format(before, #danmakus, (mp.get_time() - t_merge) * 1000))
        if before > #danmakus then
            MERGE_STATS = { before = before, after = #danmakus }
        end
    end

    -- 黑名单过滤（合并后执行）：先聚类再过滤，簇的显示文本命中才整簇丢弃；
    -- 个别成员命中但显示文本干净时簇保留完整 xN 计数（x99 不因屏蔽词缩水）。
    -- 匹配对象为合并引擎的归一化显示文本（剥离引擎追加的 xN 后缀）。
    -- 开关语义与菜单 filter_option_is_on 一致（false / "no" 均视为关）
    if options.blacklist_enabled ~= false and options.blacklist_enabled ~= "no" then
        local t_bl = mp.get_time()
        local dropped = 0
        local kept = {}
        for _, d in ipairs(danmakus) do
            local text = d.text or ""
            if d.merged_x_suffix then
                text = text:gsub("x%d+$", "")
            end
            if not is_blacklisted(text, black_patterns) then
                kept[#kept + 1] = d
            else
                dropped = dropped + 1
            end
        end
        if dropped > 0 then
            BLACKLIST_STATS = { dropped = dropped }
            danmakus = kept
            msg.verbose(("黑名单过滤: %d -> %d, 丢弃 %d, 耗时 %.0f ms"):format(
                #danmakus + dropped, #danmakus, dropped, (mp.get_time() - t_bl) * 1000))
        end
    end

    if #danmakus == 0 then
        if not force then
            show_message("该集弹幕内容为空，结束加载", 3)
            msg.verbose("该集弹幕内容为空，结束加载")
        end
        COMMENTS = {}
        return
    end

    if not force then
        msg.info("已解析 " .. #danmakus .. " 条弹幕")
    end

    local fontsize = tonumber(options.fontsize) or 50
    local fontsize_growth = tonumber(options.merge_fontsize_growth) or 8
    local fontsize_max = tonumber(options.merge_fontsize_max) or 100
    local scrolltime = tonumber(options.scrolltime) or 15
    local fixtime = tonumber(options.fixtime) or 5

    local res_x = 1920
    local res_y = 1080

    local display_height = math.max(1, math.floor(res_y * (tonumber(options.displayarea) or 1)))
    local roll_array = DanmakuArray:new(display_height)
    local fixed_array = DanmakuArray:new(display_height)

    -- 预处理弹幕，先计算时间段以便进行数量限制
    local pre_events = {}
    for _, d in ipairs(danmakus) do
        local time = d.type == 1 and math.floor(d.time + 0.5) or d.time
        local orig_time = d.type == 1 and math.floor(d.orig_time + 0.5) or d.orig_time
        local appear_time = time
        local danmaku_type = d.type

        local end_time = nil
        if danmaku_type >= 1 and danmaku_type <= 3 then
            end_time = appear_time + scrolltime
        elseif danmaku_type == 5 or danmaku_type == 4 then
            end_time = appear_time + fixtime
        end

        if end_time then
            table.insert(pre_events, {orig_time = orig_time, start_time = appear_time, end_time = end_time, danmaku = d})
        end
    end

    -- 预计算合并放大后的字号：智能密度需要它算 dispval 并原位收缩；
    -- 下方布局直接复用 danmaku.font_size
    for _, ev in ipairs(pre_events) do
        ev.danmaku.font_size = DanmakuArray.get_merged_font_size(
            fontsize, ev.danmaku.merge_count or 1, fontsize_growth, fontsize_max)
    end

    -- 密度控制：off-不控制 / simple-同屏条数上限随机丢弃（B 站行为，仅此模式读 max_screen_danmaku）/
    -- smart-pakku 式先等比收缩字号、超硬阈值再按权重概率丢弃（未合并先死，xN 合并弹幕受保护）
    local density_mode = tostring(options.density_control or "smart"):lower()
    if density_mode == "off" then
        -- 显式不控制（不能被 or 兜底吞掉）
    elseif density_mode == "simple" then
        local limit = tonumber(options.max_screen_danmaku) or 0
        if limit > 0 then
            pre_events = limit_danmaku(pre_events, limit)
        end
    else -- smart（默认；非法档位值回落 smart，绝不静默禁用）
        local level_key = tostring(options.density_level or "medium"):lower()
        local level = DENSITY_LEVELS[level_key] or DENSITY_LEVELS.medium
        if level[1] > 0 or level[2] > 0 then
            local t_dense = mp.get_time()
            local before = #pre_events
            pre_events, DENSITY_STATS = pakku_density.process(pre_events, {
                shrink_threshold = level[1],
                drop_threshold = level[2],
                base_fontsize = fontsize,
            })
            msg.verbose(("pakku 密度[%s]: %d -> %d, 缩小 %d, 丢弃 %d, 耗时 %.0f ms"):format(level_key,
                before, DENSITY_STATS.after, DENSITY_STATS.shrunk, DENSITY_STATS.dropped,
                (mp.get_time() - t_dense) * 1000))
            if DENSITY_STATS.shrunk == 0 and DENSITY_STATS.dropped == 0 then
                DENSITY_STATS = nil -- 实际无干预时不显示统计（镜像 MERGE_STATS 惯例）
            end
        end
    end

    local ass_events = {}
    for _, ev in ipairs(pre_events) do
        local d = ev.danmaku
        local appear_time = ev.start_time
        local danmaku_type = d.type
        local clean_text = ch_convert_cached(decode_html_entities(d.text))
        local text = ass_escape(clean_text)
        -- 黑名单过滤阶段的匹配基准文本（剥引擎 xN 后缀），供「屏蔽此文本」写入规则时保持同一语义
        local blacklist_key = d.text or ""
        if d.merged_x_suffix then
            blacklist_key = blacklist_key:gsub("x%d+$", "")
        end
        -- 仅样式化合并引擎生成的 ×N 后缀（merged_x_suffix 标记），
        -- 避免误样式化用户原文里天然的 x数字 结尾（如「666x3」）
        if d.merged_x_suffix then
            text = text:gsub("x(%d+)$", "{\\b1\\i1}x%1")
        end
        -- 密度阶段已预计算 danmaku.font_size（智能模式还会原位收缩），此处仅兜底
        local event_fontsize = d.font_size or DanmakuArray.get_merged_font_size(
            fontsize, d.merge_count or 1, fontsize_growth, fontsize_max
        )

        -- 颜色从十进制转为 BGR Hex
        local color = math.max(0, math.min(d.color or 0xFFFFFF, 0xFFFFFF))
        local color_hex = string.format("%06X", color)
        local r = string.sub(color_hex, 1, 2)
        local g = string.sub(color_hex, 3, 4)
        local b = string.sub(color_hex, 5, 6)
        local color_text = string.format("{\\c&H%s%s%s&}", b, g, r)

        local style, effect
        local pos, move = nil, nil

        -- 滚动弹幕 (类型 1, 2, 3)
        if danmaku_type >= 1 and danmaku_type <= 3 then
            style = "R2L"
            local text_length = get_str_width(clean_text, event_fontsize)
            local x1 = res_x + text_length / 2
            local x2 = -text_length / 2
            local y = roll_array:get_position_y(appear_time, text_length, event_fontsize, res_x, scrolltime)
            if y then
                effect = string.format("{\\move(%d, %d, %d, %d)}", x1, y, x2, y)
                move = {x1, y, x2, y}
            end

        -- 顶部弹幕 (类型 5)
        elseif danmaku_type == 5 then
            style = "TOP"
            local x = res_x / 2
            local y = fixed_array:get_fixed_y(appear_time, event_fontsize, fixtime, true)
            if y then
                effect = string.format("{\\pos(%d, %d)}", x, y)
                pos = {x, y}
            end

        -- 底部弹幕 (类型 4)
        elseif danmaku_type == 4 then
            style = "BTM"
            local x = res_x / 2
            local y = fixed_array:get_fixed_y(appear_time, event_fontsize, fixtime, false)
            if y then
                effect = string.format("{\\pos(%d, %d)}", x, y)
                pos = {x, y}
            end
        end

        if style and effect then
            text = effect .. color_text .. text
            local event = {
                orig_time = ev.orig_time,
                start_time = ev.start_time,
                end_time = ev.end_time,
                delay = ev.start_time - (ev.orig_time or ev.start_time),
                style = style,
                text = text,
                clean_text = clean_text,
                pos = pos,
                move = move,
                layer = (style == "R2L") and 0 or 1,
                source = d.source,
                font_size = event_fontsize,
                merge_count = d.merge_count or 1,
                merged_x_suffix = d.merged_x_suffix,
                blacklist_key = blacklist_key,
            }
            table.insert(ass_events, event)
        end
    end
    COMMENTS = ass_events
end
