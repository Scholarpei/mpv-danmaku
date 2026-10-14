-- 次元城 搜索/分集/弹幕 JSON 解析单元测试
-- （基于 2026-10-14 实抓的 tests/fixtures/cyc_* 样本；弹幕样本已剥离用户资料字段
-- （user_id），弹幕相关字段原样）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local cparse = require("modules/cyc_parse")
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

do -- parse_search：芙莉莲关键词（2 条目——多季番为独立 video 条目）
    local parsed = cparse.parse_search(read_file("cyc_search_frieren.json"))
    check("搜索 ok", parsed.ok)
    check("搜索条目数=2", #parsed.items == 2, ("got %d"):format(#parsed.items))
    check("首条目 video_id=3714", parsed.items[1].video_id == "3714", tostring(parsed.items[1].video_id))
    check("首条目标题", parsed.items[1].title == "葬送的芙莉莲 第二季", parsed.items[1].title)
    check("首条目 year=2026 total=10", parsed.items[1].year == 2026 and parsed.items[1].total == 10,
        utils.format_json(parsed.items[1]))
    check("次条目 video_id=2964 total=28", parsed.items[2].video_id == "2964"
        and parsed.items[2].total == 28 and parsed.items[2].year == 2023,
        utils.format_json(parsed.items[2]))
    -- 无结果：code=0 list=[] → ok 且空表（与接口错误区分）
    local empty = cparse.parse_search(read_file("cyc_search_empty.json"))
    check("空结果按无结果处理", empty.ok and #empty.items == 0)
    -- code≠0（缺 app_name 头时的 1000）为接口错误
    check("code≠0 接口错误", cparse.parse_search('{"code":1000,"msg":"app_name is required"}').ok == false)
    check("非 JSON 安全", cparse.parse_search("<html>err</html>").ok == false)
    check("空入参安全", cparse.parse_search("").ok == false)
    check("非字符串安全", cparse.parse_search(nil).ok == false)
    -- 缺 video_id 条目跳过
    local miss = cparse.parse_search('{"code":0,"data":{"list":[{"title":"a"},{"video_id":5,"title":"b"}]}}')
    check("缺 video_id 条目跳过", miss.ok and #miss.items == 1 and miss.items[1].video_id == "5")
    -- data.list 缺失（data 为 null 等畸形）按空表处理
    local nodata = cparse.parse_search('{"code":0,"data":null}')
    check("data 缺失安全", nodata.ok and #nodata.items == 0)
end

do -- parse_search：海贼王关键词（7 条目，长番/剧场版/季度篇混合）
    local parsed = cparse.parse_search(read_file("cyc_search_onepiece.json"))
    check("海贼王搜索 ok", parsed.ok)
    check("海贼王条目数=7", #parsed.items == 7, ("got %d"):format(#parsed.items))
    local main = parsed.items[7]
    check("正主 video_id=780 year=1999 total=1155", main.video_id == "780"
        and main.year == 1999 and main.total == 1155, utils.format_json(main))
    -- 剧场版条目 total=1（红发歌姬 2022）
    local movie = parsed.items[3]
    check("剧场版 total=1", movie.video_id == "2622" and movie.total == 1
        and movie.title == "航海王：红发歌姬", utils.format_json(movie))
end

do -- parse_sections：芙莉莲 S1 单页（28 集 40100..40127）
    local parsed = cparse.parse_sections(read_file("cyc_sections_frieren.json"))
    check("分集 ok", parsed.ok)
    check("分集数=28", #parsed.list == 28, ("got %d"):format(#parsed.list))
    check("首集 id=40100 标题 第01集", parsed.list[1].id == "40100"
        and parsed.list[1].title == "第01集", utils.format_json(parsed.list[1]))
    check("末集 id=40127 标题 第28集", parsed.list[28].id == "40127"
        and parsed.list[28].title == "第28集", utils.format_json(parsed.list[28]))
    check("total 取 pager=28", parsed.total == 28, tostring(parsed.total))
    -- 剧场版单集同形态
    local movie = cparse.parse_sections(read_file("cyc_sections_movie.json"))
    check("剧场版单集 ok/1集/35545", movie.ok and #movie.list == 1
        and movie.list[1].id == "35545", utils.format_json(movie.list))
    -- 长番第 1 页：48 集但 pager.total=1155（翻页由调用方继续）
    local p1 = cparse.parse_sections(read_file("cyc_sections_onepiece_p1.json"))
    check("海贼王 p1 48集", p1.ok and #p1.list == 48, ("got %d"):format(#p1.list))
    check("海贼王 p1 total=1155", p1.total == 1155, tostring(p1.total))
    check("海贼王 p1 末集 第48集/8640", p1.list[48].id == "8640"
        and p1.list[48].title == "第48集")
    -- 长番末页：3 集收尾（翻页终止的实物形态）
    local p25 = cparse.parse_sections(read_file("cyc_sections_onepiece_p25.json"))
    check("海贼王 p25 3集/末集 9747 第1155集", p25.ok and #p25.list == 3
        and p25.list[3].id == "9747" and p25.list[3].title == "第1155集",
        utils.format_json(p25.list[3]))
    -- 接口错误两口径：code=1000（player_code 缺失）/ 404（player_code 非法）
    check("code=1000 接口错误", cparse.parse_sections('{"code":1000,"msg":"player_code is required"}').ok == false)
    check("code=404 接口错误", cparse.parse_sections('{"code":404,"msg":"not found"}').ok == false)
    check("分集非 JSON 安全", cparse.parse_sections("").ok == false)
    check("分集 nil 安全", cparse.parse_sections(nil).ok == false)
    -- pager 缺失时 total 回退本页条数
    local nopager = cparse.parse_sections('{"code":0,"data":{"list":[{"id":1,"title":"第01集"}]}}')
    check("pager 缺失 total 回退条数", nopager.ok and nopager.total == 1, tostring(nopager.total))
end

do -- parse_danmaku：芙莉莲 S1 ep1（862 条全量单次返回）
    local parsed = cparse.parse_danmaku(read_file("cyc_danmaku_frieren_s1ep1.json"))
    check("弹幕 ok", parsed.ok)
    check("弹幕条数=862", #parsed.comments == 862, ("got %d"):format(#parsed.comments))
    local c1 = parsed.comments[1]
    check("首条 三刷/1.736秒/白/滚动", c1.text == "三刷" and c1.time == 1.736
        and c1.color == 16777215 and c1.mode == 1, utils.format_json(c1))
    -- 实测升序 + 防御性再排（乱序样本验证排序生效见下方合成用例）
    local asc = true
    for i = 2, #parsed.comments do
        if parsed.comments[i].time < parsed.comments[i - 1].time then asc = false break end
    end
    check("样本升序", asc)
    check("末条时间 ~1551.8", math.abs(parsed.comments[#parsed.comments].time - 1551.785) < 0.01,
        tostring(parsed.comments[#parsed.comments].time))
    -- mode 全 normal → 全滚动
    local non_scroll = 0
    for _, c in ipairs(parsed.comments) do
        if c.mode ~= 1 then non_scroll = non_scroll + 1 end
    end
    check("全样本 mode=normal 映射滚动", non_scroll == 0, ("non=%d"):format(non_scroll))
    -- 彩色弹幕（16729402 等十进制色原样保留）
    local colored = false
    for _, c in ipairs(parsed.comments) do
        if c.color ~= 16777215 then colored = true break end
    end
    check("含非白十进制色", colored)
end

do -- parse_danmaku：剧场版（534 条，time_point 跨度 6900s≈115 分钟长片形态）
    local parsed = cparse.parse_danmaku(read_file("cyc_danmaku_movie.json"))
    check("剧场版弹幕 ok/534条", parsed.ok and #parsed.comments == 534,
        ("got %d"):format(#parsed.comments))
    check("剧场版时间轴跨度>6000s", parsed.comments[#parsed.comments].time > 6000,
        tostring(parsed.comments[#parsed.comments].time))
end

do -- parse_danmaku：海贼王 ep1（177 条 14 色——彩色弹幕混合样本）
    local parsed = cparse.parse_danmaku(read_file("cyc_danmaku_onepiece_ep1.json"))
    check("海贼王弹幕 ok/177条", parsed.ok and #parsed.comments == 177,
        ("got %d"):format(#parsed.comments))
    local colors = {}
    for _, c in ipairs(parsed.comments) do colors[c.color] = true end
    local n = 0
    for _ in pairs(colors) do n = n + 1 end
    check("海贼王 14 种色", n == 14, ("got %d"):format(n))
    -- 52480 = 0x00CD00 绿色原样
    local has_green = false
    for _, c in ipairs(parsed.comments) do
        if c.color == 52480 then has_green = true break end
    end
    check("52400 段十进制色原样（0x00CD00）", has_green)
end

do -- parse_danmaku：口径区分与畸形防御（合成样本）
    -- 合法空：code=0 且 items=[] → ok 零条
    local empty = cparse.parse_danmaku('{"code":0,"data":{"count":0,"items":[]}}')
    check("合法空 ok 零条", empty.ok and #empty.comments == 0)
    -- 接口错误：code=1000（缺 app_name 头）/ 非 JSON
    check("code=1000 接口错误", cparse.parse_danmaku('{"code":1000,"msg":"app_name is required"}').ok == false)
    check("非 JSON 接口错误", cparse.parse_danmaku("<html>").ok == false)
    check("nil 安全", cparse.parse_danmaku(nil).ok == false)
    -- 畸形单条跳过不击穿整批：缺 content / 缺 time_point / 非 table
    local mixed = cparse.parse_danmaku('{"code":0,"data":{"items":['
        .. '{"content":"a","time_point":1.5,"mode":"normal","color":16777215},'
        .. '{"time_point":2.5,"mode":"normal","color":16777215},'
        .. '{"content":"","time_point":3.5,"mode":"normal"},'
        .. '{"content":"b","mode":"normal"},'
        .. '"junk",'
        .. '{"content":"c","time_point":0.5,"mode":"normal","color":"bad"}]}}')
    check("畸形跳过 ok", mixed.ok and #mixed.comments == 2,
        ("got %d"):format(#mixed.comments))
    -- 乱序样本：防御性升序再排（time 0.5 排到 1.5 前）
    check("防御性升序", mixed.comments[1].text == "c" and mixed.comments[2].text == "a",
        utils.format_json(mixed.comments))
    -- 非字符串色兜底白（"bad" → tonumber nil → 0xFFFFFF）
    check("非法色兜底白", mixed.comments[1].color == 16777215, tostring(mixed.comments[1].color))
    -- mode 防御性映射：top→5 / bottom→4 / 未知值→滚动兜底
    local modes = cparse.parse_danmaku('{"code":0,"data":{"items":['
        .. '{"content":"n","time_point":1,"mode":"normal"},'
        .. '{"content":"t","time_point":2,"mode":"top"},'
        .. '{"content":"b","time_point":3,"mode":"bottom"},'
        .. '{"content":"x","time_point":4,"mode":"weird"},'
        .. '{"content":"m","time_point":5}]}}')
    check("mode 映射 normal/top/bottom/未知/缺失",
        modes.comments[1].mode == 1 and modes.comments[2].mode == 5
            and modes.comments[3].mode == 4 and modes.comments[4].mode == 1
            and modes.comments[5].mode == 1,
        utils.format_json(modes.comments))
    -- items 缺失按空表
    local noitems = cparse.parse_danmaku('{"code":0,"data":{"count":0}}')
    check("items 缺失安全", noitems.ok and #noitems.comments == 0)
end

print(failures == 0 and "ALL PASS" or ("FAILED: " .. failures))
mp.command_native({ "quit", failures == 0 and 0 or 1 })
