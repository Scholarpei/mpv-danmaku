-- pakku 合并性能压测：模拟高密度剧集（~12000 条，withRelated 场景）
-- 运行：mpv.com --idle=once --no-config --script=<本文件>

local ROOT = "D:/software/mpv-lazy/portable_config/scripts/uosc_danmaku"
package.path = ROOT .. "/?.lua;" .. package.path

local pakku = require("modules/pakku_merge")

-- 简易可复现随机数（线性同余），保证每次运行结果可比
local seed = 42
local function rand(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n
end

local spam_pool = {}
for i = 1, 100 do
    spam_pool[i] = string.rep("哈哈哈", 1 + rand(4)) .. (i <= 20 and tostring(i) or "")
end
local words = { "前方", "高能", "泪目", "名场面", "男主", "女主", "神作", "催更", "考试", "细思极恐",
    "音乐", "绝了", "离谱", "笑死", "破防", "致敬", "回忆杀", "打斗", "作画", "经费" }

local function gen(n, duration)
    local list = {}
    for i = 1, n do
        local text
        local r = rand(100)
        if r < 40 then
            text = spam_pool[1 + rand(#spam_pool)] -- 刷屏池（大量重复/相似）
        else
            text = words[1 + rand(#words)] .. words[1 + rand(#words)] .. (r < 70 and tostring(rand(100)) or "")
        end
        local t = duration * i / n
        list[i] = { time = t, type = (rand(100) < 85) and 1 or (rand(100) < 50 and 4 or 5),
            size = 25, color = 0xFFFFFF, text = text }
    end
    table.sort(list, function(a, b) return a.time < b.time end)
    return list
end

local forcelist = pakku.parse_forcelist("^2333+=>23333|^666+=>66666")
local py_on = pakku.pinyin_available()

for _, n in ipairs({ 3000, 12000 }) do
    for _, use_pinyin in ipairs({ false, py_on }) do
        local list = gen(n, 1440)
        local t0 = mp.get_time()
        local out = pakku.merge(list, { window = 30, use_pinyin = use_pinyin, forcelist = forcelist })
        local dt = (mp.get_time() - t0) * 1000
        print(string.format("n=%d pinyin=%s: %d -> %d, %.0f ms", n,
            tostring(use_pinyin), n, #out, dt))
    end
end

-- ---------- 渲染 tick 微基准（time-pos 每帧调用的字符串构建成本） ----------
-- 新路径 build_visible_strings（构建期 bake + 每帧仅坐标插值）vs
-- 旧路径参考实现（每帧每条弹幕剥 move/实体 + fs 匹配放大正则变换）。
-- 旧实现快照自改造前 render.lua，勿随新实现更新。
do
    show_message = function() end
    require("modules/options")
    options.blacklist_path = ""
    require("modules/utils")
    require("modules/parse")
    require("modules/render")

    -- 高密度段采样：取构建后的管线输出，pos 扫过弹幕最密的区间。
    -- density_control=off 让合并后弹幕全量进布局（smart 会把高密度场景丢弃到无渲染压力）；
    -- distinct 生成器用不相似长文本（字符多重集距离 > MAX_DIST）绕开 pakku 合并衰减，
    -- 保住窗口内事件量——渲染压力来自「窗口内待遍历事件 + 可见弹幕条数」
    local function gen_distinct(n, duration)
        local list = {}
        local wlen = #words
        for i = 1, n do
            local text = table.concat({
                words[1 + rand(wlen)], words[1 + rand(wlen)], words[1 + rand(wlen)],
                words[1 + rand(wlen)], words[1 + rand(wlen)], words[1 + rand(wlen)],
                string.format("%04d", i % 10000),
            })
            local t = duration * i / n
            list[i] = { time = t, type = (rand(100) < 85) and 1 or (rand(100) < 50 and 4 or 5),
                size = 25, color = 0xFFFFFF, text = text }
        end
        table.sort(list, function(a, b) return a.time < b.time end)
        return list
    end

    local function bench_render(label, list, base_pos)
        options.density_control = "off"
        DANMAKU = { sources = { ["bench://x"] = { from = "user_custom", data = list } }, count = 1 }
        convert_danmaku_to_ass_events()
        local n_events = COMMENTS and #COMMENTS or 0

    local unpack_ref = unpack or table.unpack
    local re_entity = "&#%d+;"
    local re_fs = "\\fs(%d+)"
    local function ref_tick(pos)
        local fontname = options.fontname
        local fontsize = options.fontsize
        local opacity = tonumber(options.opacity)
        local alpha = string.format("%02X", (1 - (opacity or 0)) * 255)
        local width, height = 1920, 1080
        local lo = binary_search(COMMENTS, pos - math.max(options.scrolltime, options.fixtime),
            function(item) return item.start_time end)
        local ass_prefix = string.format(
            "{\\rDefault\\fn%s\\fs%d\\c&HFFFFFF&\\alpha&H%s\\bord%s\\shad%s\\b%s\\q2}",
            fontname, fontsize, alpha, options.outline, options.shadow, options.bold and "1" or "0")
        local low, high = {}, {}
        for i = lo, #COMMENTS do
            local event = COMMENTS[i]
            if not event then break end
            if event.start_time > pos then break end
            if event.end_time >= pos then
                local text
                if event.move then
                    local x1, y1, x2, y2 = unpack_ref(event.move)
                    local duration = event.end_time - event.start_time
                    local progress = (pos - event.start_time) / duration
                    local current_x = tonumber(x1 + (x2 - x1) * progress)
                    local current_y = tonumber(y1 + (y2 - y1) * progress)
                    local clean_text = event.text:gsub("\\move%(.-%)", "")
                    if current_y <= height * options.displayarea then
                        text = string.format("{\\pos(%.1f,%.1f)\\an8}%s", current_x, current_y, clean_text)
                    end
                else
                    local _, cy = unpack_ref(event.pos or {})
                    if cy and not (tonumber(cy) > height * options.displayarea) then
                        text = string.format("{\\an8}%s", event.text)
                    end
                end
                if text then
                    text = text:gsub(re_entity, "")
                    if text:match(re_fs) then
                        text = text:gsub(re_fs, function(size)
                            return string.format("\\fs%d", math.floor((tonumber(size) or 0) * 1.5))
                        end)
                    end
                    local efp = ""
                    if event.font_size then
                        local adj = math.max(1, math.floor(event.font_size + fontsize - (tonumber(options.fontsize) or fontsize)))
                        efp = string.format("{\\fs%d}", adj)
                    end
                    local ass_text = ass_prefix .. efp .. text
                    if event.layer == nil or tonumber(event.layer) == 0 then
                        low[#low + 1] = ass_text
                    else
                        high[#high + 1] = ass_text
                    end
                end
            end
        end
        return table.concat(low, '\n'), table.concat(high, '\n')
    end

        local TICKS = 1000

        local t0 = mp.get_time()
        for k = 0, TICKS - 1 do build_visible_strings(base_pos + k * 0.016) end
        local new_ms = (mp.get_time() - t0) * 1000 / TICKS

        t0 = mp.get_time()
        for k = 0, TICKS - 1 do ref_tick(base_pos + k * 0.016) end
        local old_ms = (mp.get_time() - t0) * 1000 / TICKS

        -- 高能窗口可见条数（供解读 ms/frame）
        local nl, nh = build_visible_strings(base_pos)
        local visible = 0
        for line in (nl or ""):gmatch("[^\n]+") do visible = visible + 1 end
        for line in (nh or ""):gmatch("[^\n]+") do visible = visible + 1 end

        print(string.format("render tick[%s]: new %.3f ms/frame, old(ref) %.3f ms/frame, speedup %.1fx, events=%d visible=%.0f",
            label, new_ms, old_ms, old_ms / math.max(new_ms, 1e-9), n_events, visible))
    end

    bench_render("12000条/1440s 稀疏(含合并)", gen(12000, 1440), 720)
    bench_render("12000条/300s 高密度(不相似长文本)", gen_distinct(12000, 300), 150)
end

print("BENCH DONE")
-- os.exit 直杀：mpv 正常 quit 的关机路径在 Windows 控制台代理下偶发挂起（测试环境已知问题）
os.exit(0)
