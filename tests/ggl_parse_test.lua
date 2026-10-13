-- girigirilove 搜索/详情页/播放页/弹幕 JSON 解析单元测试
-- （基于 2026-10-13 实抓的 tests/fixtures/ggl_* 样本）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local gparse = require("modules/ggl_parse")
local b64 = require("modules/base64")
local utils = require("mp.utils")

local function read_file(name)
    local f = assert(io.open(script_dir .. "/fixtures/" .. name, "rb"))
    local content = f:read("*all")
    f:close()
    return content
end

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

do -- parse_search：JOJO 关键词 ajax/suggest（7 条，id 即 GV 号）
    local parsed = gparse.parse_search(read_file("ggl_suggest.json"))
    check("搜索 ok", parsed.ok)
    check("搜索条目数=7", #parsed.items == 7, ("got %d"):format(#parsed.items))
    check("首条目 gv_id=26868", parsed.items[1].gv_id == "26868", tostring(parsed.items[1].gv_id))
    check("首条目标题", parsed.items[1].title == "JOJO的奇妙冒险 飙马野郎", parsed.items[1].title)
    check("第二条目 gv_id=7141", parsed.items[2].gv_id == "7141", tostring(parsed.items[2].gv_id))
    check("末条目 gv_id=201", parsed.items[7].gv_id == "201", tostring(parsed.items[7].gv_id))
    -- 无结果：code=1 total=0 list=[] → ok 且空表（与接口错误区分）
    check("空结果按无结果处理", gparse.parse_search(read_file("ggl_suggest_empty.json")).ok
        and #gparse.parse_search(read_file("ggl_suggest_empty.json")).items == 0)
    -- code≠1（参数错误 1001）为接口错误
    check("code≠1 接口错误", gparse.parse_search('{"code":1001,"msg":"参数错误"}').ok == false)
    check("非 JSON 安全", gparse.parse_search("<html>err</html>").ok == false)
    check("空入参安全", gparse.parse_search("").ok == false)
    check("非字符串安全", gparse.parse_search(nil).ok == false)
    -- 同 id 去重
    local dup = gparse.parse_search('{"code":1,"list":[{"id":1,"name":"a"},{"id":1,"name":"b"}]}')
    check("同 id 去重", dup.ok and #dup.items == 1 and dup.items[1].title == "a")
end

do -- parse_detail：JOJO 飙马野郎详情页（2 线路 繁中/简中 × 4 集）
    local parsed = gparse.parse_detail(read_file("ggl_detail.html"))
    check("详情 ok", parsed.ok)
    check("线路数=2", #parsed.lines == 2, ("got %d"):format(#parsed.lines))
    -- 线路标签取自 anthology-tab（页头导航 日番/电影 等同为 swiper-slide，不锚定会混入）
    check("线路标签 繁中/简中", parsed.lines[1].label == "繁中" and parsed.lines[2].label == "简中",
        parsed.lines[1].label .. "/" .. tostring(parsed.lines[2] and parsed.lines[2].label))
    check("首线路 4 集", #parsed.lines[1].episodes == 4, ("got %d"):format(#parsed.lines[1].episodes))
    local e1 = parsed.lines[1].episodes[1]
    check("首集 gv/src/ep=26868/1/1", e1.gv == "26868" and e1.src == 1 and e1.ep == 1,
        utils.format_json(e1))
    check("首集标签 先行01", e1.label == "先行01", tostring(e1.label))
    check("第2集标签 02", parsed.lines[1].episodes[2].label == "02",
        tostring(parsed.lines[1].episodes[2].label))
    check("次线路 src=2 同 4 集", #parsed.lines[2].episodes == 4
        and parsed.lines[2].episodes[1].src == 2 and parsed.lines[2].episodes[1].ep == 1,
        utils.format_json(parsed.lines[2].episodes[1]))
    -- 页面顺序升序即正片序（集数号递增）
    check("全线路集数升序", (function()
        for _, line in ipairs(parsed.lines) do
            for i = 2, #line.episodes do
                if line.episodes[i].ep <= line.episodes[i - 1].ep then return false end
            end
        end
        return true
    end)())
end

do -- parse_detail：冷门番 罗梅莉亚战记（2 线路 × 2 集，标签纯数字 01/02）
    local parsed = gparse.parse_detail(read_file("ggl_detail_cold.html"))
    check("冷门番 ok", parsed.ok)
    check("冷门番 2 线路各 2 集", #parsed.lines == 2
        and #parsed.lines[1].episodes == 2 and #parsed.lines[2].episodes == 2)
    local e1 = parsed.lines[1].episodes[1]
    check("冷门番首集 gv/src/ep=27224/1/1 标签 01",
        e1.gv == "27224" and e1.src == 1 and e1.ep == 1 and e1.label == "01",
        utils.format_json(e1))
end

do -- parse_detail：剧场版 银魂 吉原大炎上（2 线路 × 1 集，标签 1080P）
    local parsed = gparse.parse_detail(read_file("ggl_detail_movie.html"))
    check("剧场版 ok", parsed.ok)
    check("剧场版 2 线路各 1 集", #parsed.lines == 2
        and #parsed.lines[1].episodes == 1 and #parsed.lines[2].episodes == 1)
    local e1 = parsed.lines[1].episodes[1]
    check("剧场版首集 gv=27164 标签 1080P",
        e1.gv == "27164" and e1.src == 1 and e1.ep == 1 and e1.label == "1080P",
        utils.format_json(e1))
end

do -- parse_detail：合成边界
    check("空页面安全", gparse.parse_detail("<html></html>").ok == false)
    check("非字符串安全", gparse.parse_detail(nil).ok == false)
    -- tab 缺失时线路标签兜底「线路N」
    local notab = gparse.parse_detail('<div class="anthology-list top20"><div class="anthology-list-box">'
        .. '<ul class="anthology-list-play size"><li><a class="hide" href="/playGV9-1-1/">01</a></li>'
        .. '</ul></div></div>')
    check("tab 缺失标签兜底", notab.ok and #notab.lines == 1 and notab.lines[1].label == "线路1",
        utils.format_json(notab.lines))
    -- 集数链接带尾斜杠两种写法均可
    check("无尾斜杠链接也匹配", (function()
        local p = gparse.parse_detail('<ul class="anthology-list-play"><li>'
            .. '<a href="/playGV5-2-3">03</a></li></ul>')
        return p.ok and p.lines[1].episodes[1].gv == "5"
            and p.lines[1].episodes[1].src == 2 and p.lines[1].episodes[1].ep == 3
    end)())
end

do -- parse_player：JOJO ep1 播放页（player_aaaa encrypt=2 → base64+percent 解出裸 m3u8）
    local parsed = gparse.parse_player(read_file("ggl_play_l1.html"))
    check("播放页 ok", parsed.ok)
    check("m3u8 解码（繁中线路）", parsed.m3u8
        == "https://akua.girigirilove.com/zijian/oldanime/2026/04/cht/JoJosBizarreAdventureS6CHT/01/playlist.m3u8",
        tostring(parsed.m3u8))
    check("from=cht", parsed.from == "cht", tostring(parsed.from))
    -- 简中线路（from=chs）：m3u8 路径无 cht/ 段——两线路播放地址不同（弹幕接口按资源名
    -- 模糊匹配同池，缓存键仍带线路 src 防串台）
    local p2 = gparse.parse_player(read_file("ggl_play_l2.html"))
    check("简中线路 ok", p2.ok and p2.from == "chs")
    check("简中线路 m3u8（与繁中不同）", p2.m3u8
        == "https://akua.girigirilove.com/zijian/oldanime/2026/04/JoJosBizarreAdventureS6/01/playlist.m3u8"
        and p2.m3u8 ~= parsed.m3u8, tostring(p2.m3u8))
    -- 剧场版：单集无 {集} 段
    local pm = gparse.parse_player(read_file("ggl_play_movie.html"))
    check("剧场版 m3u8 无集数段", pm.ok and pm.m3u8
        == "https://akua.girigirilove.com/zijian/oldanime/2026/07/cht/GintamaYoshiwarainFlamesCHT/playlist.m3u8",
        tostring(pm.m3u8))
end

do -- parse_player：合成边界（encrypt 0/1 档、安全校验、缺字段）
    local plain = "https://test.example/anime/2026/01/cht/StubCHT/01/playlist.m3u8"
    -- encrypt=0 明文直传
    local h0 = '<script>var player_aaaa={"flag":"play","encrypt":0,"url":"' .. plain
        .. '","from":"DB","id":"9"};</script>'
    local p0 = gparse.parse_player(h0)
    check("encrypt=0 明文", p0.ok and p0.m3u8 == plain and p0.from == "DB")
    -- encrypt=1 纯 base64
    local h1 = '<script>player_aaaa={"flag":"play","encrypt":1,"url":"' .. b64.encode(plain)
        .. '","from":"cht","id":"9"};</script>'
    local p1 = gparse.parse_player(h1)
    check("encrypt=1 base64", p1.ok and p1.m3u8 == plain)
    -- encrypt=2 base64(percent)：站方为逐字符 %XX 全编码（含字母数字也编码）
    local pct = plain:gsub(".", function(c) return string.format("%%%02X", c:byte()) end)
    local h2 = '<script>player_aaaa={"flag":"play","encrypt":2,"url":"' .. b64.encode(pct)
        .. '","from":"chs","id":"9"};</script>'
    local p2 = gparse.parse_player(h2)
    check("encrypt=2 全编码解码", p2.ok and p2.m3u8 == plain, tostring(p2.m3u8))
    -- 解出地址含引号（不安全字符，不能直拼 JSON body）整体拒绝
    local hq = '<script>player_aaaa={"encrypt":0,"url":"https://x.example/a\\"b.m3u8"};</script>'
    check("不安全字符拒绝", gparse.parse_player(hq).ok == false)
    check("缺 player_aaaa 无匹配", gparse.parse_player("<html><body></body></html>").ok == false)
    check("空页面安全", gparse.parse_player("").ok == false)
    check("非字符串安全", gparse.parse_player(nil).ok == false)
end

do -- parse_danmaku：JOJO ep1（266 条，mode 1滚动/2顶/3底 → B站 1/5/4）
    local parsed = gparse.parse_danmaku(read_file("ggl_danmaku.json"))
    check("弹幕 ok", parsed.ok)
    check("条数=266", #parsed.comments == 266, ("got %d"):format(#parsed.comments))
    local n1, n4, n5 = 0, 0, 0
    for _, c in ipairs(parsed.comments) do
        if c.mode == 1 then n1 = n1 + 1 elseif c.mode == 4 then n4 = n4 + 1
        elseif c.mode == 5 then n5 = n5 + 1 end
    end
    check("mode 映射分布 1×262/4×1/5×3", n1 == 262 and n4 == 1 and n5 == 3,
        ("1:%d 4:%d 5:%d"):format(n1, n4, n5))
    -- 首条：文本在 content（text 字段恒空）、色在 style.color
    local first = parsed.comments[1]
    check("首条形状", first.time == 31.018983 and first.mode == 1
        and first.color == 16777215 and first.text == "没有弹幕嘛",
        utils.format_json(first))
    -- 8 位色 #ffffffff：剥 alpha 取前 6 位
    local alpha_ok = false
    for _, c in ipairs(parsed.comments) do
        if c.time == 2219 and c.text == "脚力这么大？" then
            alpha_ok = c.color == 16777215
            break
        end
    end
    check("8 位色剥 alpha（#ffffffff→16777215）", alpha_ok)
    -- 顶部弹幕（mode 2→B站 5）带非白颜色 #ff33ff
    local top_ok = false
    for _, c in ipairs(parsed.comments) do
        if c.time == 41.271802 and c.mode == 5 and c.color == 16724991
            and c.text:sub(1, 4) == "jooo" then
            top_ok = true
            break
        end
    end
    check("顶部弹幕 mode 2→5 与 hex 色换算", top_ok)
    -- 非白颜色 #a0ee00 → 10546688
    local color_ok = false
    for _, c in ipairs(parsed.comments) do
        if c.time == 1341.125773 and c.text == "這時代是否沒替身使者？" then
            color_ok = c.color == 10546688
            break
        end
    end
    check("hex 色换算 #a0ee00→10546688", color_ok)
    -- time 可为整数（JSON int）
    check("整数 time 透传", (function()
        for _, c in ipairs(parsed.comments) do
            if c.time == 2219 then return true end
        end
        return false
    end)())
end

do -- parse_danmaku：剧场版 银魂 吉原大炎上（18 条稀疏样本，全滚动）
    local parsed = gparse.parse_danmaku(read_file("ggl_danmaku_movie.json"))
    check("剧场版弹幕 ok", parsed.ok)
    check("剧场版条数=18", #parsed.comments == 18, ("got %d"):format(#parsed.comments))
    check("剧场版首条", parsed.comments[1].time == 205
        and parsed.comments[1].text == "要是我把这片街都烧了呢？",
        utils.format_json(parsed.comments[1]))
    local all_mode1 = true
    for _, c in ipairs(parsed.comments) do
        if c.mode ~= 1 then all_mode1 = false break end
    end
    check("剧场版全为滚动弹幕", all_mode1)
end

do -- parse_danmaku：合法空 / 接口错误 / 畸形单条（两口径区分：空≠错误）
    check("合法空（code=1 info=[]）ok 零条",
        gparse.parse_danmaku('{"code":1,"msg":"success","info":[]}').ok
        and #gparse.parse_danmaku('{"code":1,"msg":"success","info":[]}').comments == 0)
    check("code≠1 接口错误", gparse.parse_danmaku('{"code":0,"msg":"error"}').ok == false)
    check("非 JSON 安全", gparse.parse_danmaku("<html>err</html>").ok == false)
    check("空入参安全", gparse.parse_danmaku("").ok == false)
    check("非字符串安全", gparse.parse_danmaku(nil).ok == false)
    -- 畸形单条（缺 time / 空 content / 缺 scroll_json）跳过不击穿整批
    local mixed = gparse.parse_danmaku('{"code":1,"info":['
        .. '{"scroll_json":{"mode":1,"time":"x","content":"畸形","style":{"color":"#ffffff"}}},'
        .. '{"scroll_json":{"mode":1,"time":1.5,"content":"","style":{"color":"#ffffff"}}},'
        .. '{"other":1},'
        .. '{"scroll_json":{"mode":2,"time":2.5,"content":"顶","style":{"color":"#ff33ff"}}}]}')
    check("畸形条目跳过不击穿", mixed.ok and #mixed.comments == 1
        and mixed.comments[1].text == "顶" and mixed.comments[1].mode == 5
        and mixed.comments[1].color == 16724991)
    -- 缺 style / mode 未知 → 白色 / 滚动兜底（APlayer modeName default=scroll 同口径）
    local edge = gparse.parse_danmaku('{"code":1,"info":['
        .. '{"scroll_json":{"mode":9,"time":3.5,"content":"未知模式"}}]}')
    check("未知 mode 按滚动兜底", edge.ok and #edge.comments == 1
        and edge.comments[1].mode == 1 and edge.comments[1].color == 16777215)
    -- code 为字符串数字亦认
    check("字符串 code 认可", gparse.parse_danmaku('{"code":"1","info":[]}').ok == true)
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
-- os.exit 直杀：mpv 正常 quit 的关机路径在 Windows 控制台代理下偶发挂起（测试环境已知问题）
os.exit(failures > 0 and 1 or 0)
