-- 芒果解析/条目构建单元测试（基于 2026-10 实抓的 tests/fixtures 样本）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local utils = require("mp.utils")
local gparse = require("modules/mgtv_parse")
require("apis/mgtv_search") -- build_mgtv_search_items（全局）；加载仅注册消息

local function read_fixture(name)
    local path = script_dir .. "/fixtures/" .. name
    local f = assert(io.open(path, "rb"))
    local content = f:read("*all")
    f:close()
    return assert(utils.parse_json(content), "fixture 解析失败: " .. name)
end

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

do -- parse_search：去有风的地方搜索样本（芒果版权 source=''，站外条目 clipId 空）
    local parsed = gparse.parse_search(read_fixture("mgtv_search.json"))
    check("搜索 ok", parsed.ok)
    check("搜索条目数>=1", #parsed.items >= 1)
    local it = parsed.items[1]
    check("条目1字段", it ~= nil and it.clip_id == "510924"
        and it.title == "去有风的地方" and it.year == 2023 and it.type_name == "电视剧")
    check("空入参安全", gparse.parse_search(nil).ok == false)
    check("无数据响应", #gparse.parse_search({ data = {} }).items == 0)
end

do -- parse_search：站外/无clipId 过滤（source=qq 或 clipId 空）
    local fake = {
        data = { contents = {
            { type = "mediaRebirth", data = {
                { clipId = "", source = "qq", title = "家有儿女2", desc = { "类型: 电视剧 / 2005 / 内地" } },
                { clipId = "111", source = "", title = "芒果剧", desc = { "类型: 电视剧 / 2023 / 内地" } },
                { clipId = "222", source = "imgo", title = "芒果综艺", desc = { "类型: 综艺 / 2024 / 内地" } },
                { clipId = "333", source = "qiyi", title = "爱奇艺源", desc = { "类型: 电视剧 / 2023" } },
                { clipId = "111", source = "", title = "重复clipId", desc = { "类型: 电视剧 / 2023" } },
            } },
            { type = "shortVideoMerge", data = { { clipId = "999", source = "", title = "短视频" } } },
        } },
    }
    local parsed = gparse.parse_search(fake)
    check("站外/空clipId/重复过滤", #parsed.items == 2
        and parsed.items[1].clip_id == "111" and parsed.items[2].clip_id == "222")
    check("综艺类型解析", parsed.items[2].type_name == "综艺")
    check("无desc回退", gparse.parse_search({ data = { contents = {
        { type = "mediaRebirth", data = { { clipId = "55", source = "", title = "无desc", desc = nil } } } } } })
        .items[1].type_name == "剧集")
end

do -- parse_showlist：电视剧样本（40 集，t2=第N集）
    local parsed = gparse.parse_showlist(read_fixture("mgtv_episodes_drama.json"), "510924")
    check("剧分集 ok", parsed.ok)
    check("剧月份表=1", #parsed.months == 1)
    check("剧正片数=40", #parsed.episodes == 40)
    check("剧条目字段", parsed.episodes[1].video_id == "18030368"
        and parsed.episodes[1].t2 == "第1集" and parsed.episodes[1].t1 == "南星给红豆留下遗言")
    check("src_clip_id 过滤", gparse.parse_showlist(
        { data = { list = { { video_id = "1", src_clip_id = "other", t1 = "x", t2 = "", isnew = "0" } } } },
        "510924").ok and #gparse.parse_showlist(
        { data = { list = { { video_id = "1", src_clip_id = "other", t1 = "x", t2 = "", isnew = "0" } } } },
        "510924").episodes == 0)
end

do -- parse_showlist：综艺样本（黑名单词过滤 isnew 预告过滤 + 月份表）
    local cur = gparse.parse_showlist(read_fixture("mgtv_variety_cur.json"), "815824")
    check("综艺月份表=6", #cur.months == 6 and cur.months[1] == "202606")
    check("综艺黑名单过滤（侦藏版特辑类）", #cur.episodes == 0)
    local m05 = gparse.parse_showlist(read_fixture("mgtv_variety_202605.json"), "815824")
    -- 202605 样本：超前彩蛋/轻量版/收官宴被黑名单过滤，剩 12案上/下 2 条
    check("综艺衍生过滤后=2", #m05.episodes == 2, ("got %d"):format(#m05.episodes))
    check("正片保留", m05.episodes[1].t1:find("12案", 1, true) ~= nil)
end

do -- merge_month_episodes：剧（t2=第N集）/综艺（t2=日期）两路标题 + 月序拼接
    local drama = gparse.merge_month_episodes({ {
        { video_id = "v1", t1 = "南星给红豆留下遗言", t2 = "第1集" },
        { video_id = "v2", t1 = "阿遥送红豆回小院", t2 = "第2集" },
    } })
    check("剧标题合并", #drama == 2 and drama[1].title == "第1集 南星给红豆留下遗言")

    local variety = gparse.merge_month_episodes({
        { { video_id = "a", t1 = "1案：开端", t2 = "2026-01-05" },
          { video_id = "b", t1 = "1案：开端（下）", t2 = "2026-01-06" } },
        { { video_id = "c", t1 = "2案：发展", t2 = "2026-02-05" } },
    })
    check("综艺期数连续编号", #variety == 3
        and variety[1].title == "第1期 2026-01-05 1案：开端"
        and variety[3].title == "第3期 2026-02-05 2案：发展")

    local odd = gparse.merge_month_episodes({ { { video_id = "x", t1 = "无t2", t2 = "" } } })
    check("无t2回退标题", odd[1].title == "无t2")
    check("空入参安全", #gparse.merge_month_episodes({}) == 0)
end

do -- build_mgtv_search_items：条目形状
    local items = build_mgtv_search_items({
        { clip_id = "c1", title = "剧A", year = 2023, type_name = "电视剧" },
        { clip_id = "c2", title = "艺B", year = "2024", type_name = "综艺" },
    })
    check("条目数", #items == 2)
    check("条目1形状", items[1].title == "剧A" and items[1].hint == "电视剧 | 2023"
        and items[1].value[3] == "get-mg-event" and items[1].value[4] == "c1"
        and items[1].value[5] == "剧A" and items[1].value[6] == "2023"
        and items[1].value[7] == "电视剧")
    check("空入参安全", #build_mgtv_search_items({}) == 0)
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
