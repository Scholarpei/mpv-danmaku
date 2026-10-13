-- ezdmw 搜索页/详情页/播放页/弹幕 XML 解析单元测试
-- （基于 2026-10-13 实抓的 tests/fixtures/ezd_* 样本）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local eparse = require("modules/ezdmw_parse")
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

do -- parse_search：Re:0 关键词搜索页（some_drama 区 5 条 bangumi + 不闭合注释标题 + 瀑布流推荐区）
    local parsed = eparse.parse_search(read_file("ezd_search.html"))
    check("搜索 ok", parsed.ok)
    check("搜索条目数=5", #parsed.items == 5, ("got %d"):format(#parsed.items))
    -- 首条：标题前有【不闭合】注释（<!--<img/> 12万</span>-->），先剥注释再剥标签才拿得到
    check("首条目 bangumiId=80918", parsed.items[1].bangumi_id == "80918", parsed.items[1].bangumi_id)
    check("首条目标题（不闭合注释剥离）", parsed.items[1].title == "Re:Monster 怪物转生",
        parsed.items[1].title)
    check("末条目 bangumiId=4728", parsed.items[5].bangumi_id == "4728" and parsed.items[5].title == "Re:CREATORS",
        utils.format_json(parsed.items[5]))
    -- 瀑布流推荐区（/Index/up_details/ 链接）不得混入：恰 5 条即证明只取搜索结果区
    check("推荐区不混入（恰 5 条）", #parsed.items == 5)
    -- 无结果页：some_drama 区整段缺席 → ok 且空表
    check("空页面按无结果处理", eparse.parse_search("<html><body></body></html>").ok
        and #eparse.parse_search("<html><body></body></html>").items == 0)
    check("空入参安全", eparse.parse_search("").ok and #eparse.parse_search("").items == 0)
    check("非字符串安全", eparse.parse_search(nil).ok == false)
end

do -- parse_detail：Re:0 第四季详情页（19 集 × 3 线路，主线 circuit_switch1 降序）
    local parsed = eparse.parse_detail(read_file("ezd_detail.html"))
    check("详情 ok", parsed.ok)
    check("集数=19（仅主线线路，备用/导入线路不混入）", #parsed.episodes == 19,
        ("got %d"):format(#parsed.episodes))
    -- 页面原始顺序为降序（末集在前），须按集数升序排列
    check("升序首集=第1集 videoId=98626", parsed.episodes[1].ep == 1
        and parsed.episodes[1].video_id == "98626", utils.format_json(parsed.episodes[1]))
    check("升序第10集 videoId=100141", parsed.episodes[10].ep == 10
        and parsed.episodes[10].video_id == "100141", utils.format_json(parsed.episodes[10]))
    check("升序末集=第19集 videoId=102578", parsed.episodes[19].ep == 19
        and parsed.episodes[19].video_id == "102578", utils.format_json(parsed.episodes[19]))
    check("全表集数升序", (function()
        for i = 2, #parsed.episodes do
            if parsed.episodes[i].ep <= parsed.episodes[i - 1].ep then return false end
        end
        return true
    end)())
    check("空页面安全", eparse.parse_detail("<html></html>").ok == false)
    check("非字符串安全", eparse.parse_detail(nil).ok == false)
end

do -- parse_detail：单集剧场版（命运石之门 负荷领域的既视感，仅 1 集同样是 circuit_switch1）
    local parsed = eparse.parse_detail(read_file("ezd_detail_movie.html"))
    check("剧场版 ok", parsed.ok)
    check("剧场版单集 videoId=1506", #parsed.episodes == 1
        and parsed.episodes[1].ep == 1 and parsed.episodes[1].video_id == "1506",
        utils.format_json(parsed.episodes))
end

do -- parse_player：Re:0 第四季 ep19 播放页（弹幕播放器 iframe 内嵌 nk + sign）
    local parsed = eparse.parse_player(read_file("ezd_player.html"))
    check("播放页 ok", parsed.ok)
    check("nk=clksdysjsh4/clksdysjsh4_19", parsed.nk == "clksdysjsh4/clksdysjsh4_19", tostring(parsed.nk))
    check("sign=32位hex", parsed.sign == "22a77912baa6a004929ef0838a519902", tostring(parsed.sign))
    -- 同页另有评论区 iframe（comment_index=nk=98626）：锚定 danmuku 播放器，不得误取
    check("评论区 iframe 不误取", parsed.nk ~= "98626")
    check("仅评论区 iframe 无匹配", eparse.parse_player(
        '<iframe src="/comment/?comment_index=nk=98626"></iframe>').ok == false)
    check("备用播放域也可提取", (function()
        local p = eparse.parse_player('<iframe src="https://player.danmuzf.vip/danmuku/'
            .. '?nk=abc/abc_01&name=x&sign=deadbeefdeadbeefdeadbeefdeadbeef"></iframe>')
        return p.ok and p.nk == "abc/abc_01" and p.sign == "deadbeefdeadbeefdeadbeefdeadbeef"
    end)())
    check("缺 sign 无匹配", eparse.parse_player(
        '<iframe src="https://player.ezdmw.com/danmuku/?nk=abc/abc_01"></iframe>').ok == false)
    check("空页面安全", eparse.parse_player("<html></html>").ok == false)
    check("非字符串安全", eparse.parse_player(nil).ok == false)
end

do -- parse_danmaku：Re:0 第四季 ep19（1701 条，B站标准 XML）
    local parsed = eparse.parse_danmaku(read_file("ezd_danmaku.xml"))
    check("弹幕 ok", parsed.ok)
    check("条数=1701", #parsed.comments == 1701, ("got %d"):format(#parsed.comments))
    -- 首条为站点系统消息（time=0、color=16707842、user=admins）
    local first = parsed.comments[1]
    check("首条系统消息形状", first.time == 0 and first.mode == 1
        and first.color == 16707842 and first.text:find("弹幕已装载", 1, true) ~= nil,
        utils.format_json(first))
    -- p 字段序 time,mode,fontsize,color：mode/color 字段换算正确（mode 1滚动 4底 5顶）
    local n1, n4, n5 = 0, 0, 0
    for _, c in ipairs(parsed.comments) do
        if c.mode == 1 then n1 = n1 + 1 elseif c.mode == 4 then n4 = n4 + 1
        elseif c.mode == 5 then n5 = n5 + 1 end
    end
    check("mode 分布 1×1369/4×44/5×288", n1 == 1369 and n4 == 44 and n5 == 288,
        ("1:%d 4:%d 5:%d"):format(n1, n4, n5))
    -- 文本实体反转义（实抓 &lt; 条目）
    local entity_ok = false
    for _, c in ipairs(parsed.comments) do
        if c.text == "贝地表情好可爱<3" then entity_ok = true break end
    end
    check("实体反转义 &lt;→<", entity_ok)
    check("时间字段为秒（末条 >2400s）", parsed.comments[#parsed.comments].time > 2400,
        tostring(parsed.comments[#parsed.comments].time))
end

do -- parse_danmaku：完结老番 命运石之门 ep1（14 条，主线资源弹幕稀少的真实边界）
    local parsed = eparse.parse_danmaku(read_file("ezd_danmaku_sgv.xml"))
    check("老番弹幕 ok", parsed.ok)
    check("老番条数=14", #parsed.comments == 14, ("got %d"):format(#parsed.comments))
    local all_mode1 = true
    for _, c in ipairs(parsed.comments) do
        if c.mode ~= 1 then all_mode1 = false break end
    end
    check("老番全为滚动弹幕", all_mode1)
end

do -- parse_danmaku：冷门 从零开始的魔法书 ep1（1420 条，冷门番弹幕依旧丰富）
    local parsed = eparse.parse_danmaku(read_file("ezd_danmaku_cold.xml"))
    check("冷门弹幕 ok", parsed.ok)
    check("冷门条数=1420", #parsed.comments == 1420, ("got %d"):format(#parsed.comments))
    local n5 = 0
    for _, c in ipairs(parsed.comments) do
        if c.mode == 5 then n5 = n5 + 1 end
    end
    check("冷门顶部弹幕 345 条", n5 == 345, ("got %d"):format(n5))
    -- 实体反转义（实抓 &amp; 条目）
    local entity_ok = false
    for _, c in ipairs(parsed.comments) do
        if c.text == "白虎&白虎" then entity_ok = true break end
    end
    check("实体反转义 &amp;→&", entity_ok)
end

do -- parse_danmaku：合成边界（空 XML / 畸形条目 / &amp;lt; 单次解码）
    local parsed = eparse.parse_danmaku("<?xml version='1.0' encoding='utf-8'?><i></i>")
    check("空 XML ok 零条", parsed.ok and #parsed.comments == 0)
    check("空入参安全", eparse.parse_danmaku("").ok and #eparse.parse_danmaku("").comments == 0)
    check("非字符串安全", eparse.parse_danmaku(nil).ok == false)
    -- p 字段不足 4 位（缺 color）的条目跳过，不击穿整批
    local mixed = eparse.parse_danmaku('<i><d p="1.5,1,22">畸形</d>'
        .. '<d p="2.5,5,25,16711680,0,0,u,2">顶</d></i>')
    check("畸形条目跳过不击穿", mixed.ok and #mixed.comments == 1
        and mixed.comments[1].text == "顶" and mixed.comments[1].mode == 5
        and mixed.comments[1].color == 16711680)
    -- &amp;lt; 应解码为字面 "<"（&amp; 最后解码，避免二次解码）
    local esc = eparse.parse_danmaku('<i><d p="1,1,25,16777215,0,0,u,1">&amp;lt;</d></i>')
    check("转义序列单次解码", esc.ok and #esc.comments == 1 and esc.comments[1].text == "&lt;",
        utils.format_json(esc.comments))
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
-- os.exit 直杀：mpv 正常 quit 的关机路径在 Windows 控制台代理下偶发挂起（测试环境已知问题）
os.exit(failures > 0 and 1 or 0)
