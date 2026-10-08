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

print("BENCH DONE")
mp.commandv("quit")
