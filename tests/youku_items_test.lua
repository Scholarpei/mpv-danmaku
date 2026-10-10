-- 优酷解析/条目构建单元测试（基于 2026-10 实抓的 tests/fixtures 样本）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local utils = require("mp.utils")
local yparse = require("modules/youku_parse")
require("apis/youku_search") -- build_youku_search_items（全局）；加载仅注册消息

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

do -- parse_search：知否搜索样本（TV版/DVD版 两条优酷版权条目）
    local parsed = yparse.parse_search(read_fixture("youku_search.json"))
    check("搜索 ok", parsed.ok)
    check("搜索条目数=2", #parsed.items == 2)
    local it = parsed.items[1]
    check("条目1字段", it ~= nil and it.show_id ~= nil and it.title ~= ""
        and it.year == 2018 and it.type_name == "电视剧")
    check("条目集数", parsed.items[1].episode_total == 78 and parsed.items[2].episode_total == 73)
    check("空入参安全", yparse.parse_search(nil).ok == false)
    check("无组件响应", #yparse.parse_search({}).items == 0)
end

do -- parse_search：站外版权条目过滤（isYouku=0/hasYouku=0 的腾讯源条目必须丢弃）
    local fake = {
        pageComponentList = {
            { componentMap = { ["1027"] = { componentId = "H5ShowCard", data = {
                { showId = "out1", isYouku = 0, hasYouku = 0, sourceName = "腾讯",
                  titleDTO = { displayName = "庆余年" }, feature = "2019 · 电视剧 · 中国" },
                { showId = "in1", isYouku = 1, hasYouku = 1,
                  titleDTO = { displayName = "知否知否应是绿肥红瘦" }, feature = "2018 · 电视剧 · 中国" },
                { showId = "in2", isYouku = -1, hasYouku = 1,
                  titleDTO = { displayName = "某剧" }, feature = "2020 · 综艺 · 中国" },
                { showId = "in3", isYouku = 1, hasYouku = 1,
                  titleDTO = { displayName = "某剧<em>解读</em>特辑" }, feature = "2020 · 综艺 · 中国" },
            } } } },
        },
    }
    local parsed = yparse.parse_search(fake)
    check("站外过滤+黑名单", #parsed.items == 2
        and parsed.items[1].show_id == "in1" and parsed.items[2].show_id == "in2")
    check("hasYouku 兜底类型", parsed.items[2].type_name == "综艺")
end

do -- parse_episodes：知否 80 条样本（正片 78，末尾 2 条花絮 seq>stage）
    local parsed = yparse.parse_episodes(read_fixture("youku_episodes.json"))
    check("分集 ok", parsed.ok)
    check("total=80", parsed.total == 80)
    check("正片数=78", #parsed.episodes == 78)
    check("第1集 vid", parsed.episodes[1].vid == "XMzk4MDUzNTA1Mg==")
    check("published 保留", parsed.episodes[1].published:match("^2018%-12%-25") ~= nil)
    check("花絮被过滤", parsed.episodes[78].vid ~= nil and #parsed.episodes == 78)
    check("空入参安全", yparse.parse_episodes(nil).ok == false)
end

do -- build_youku_search_items：条目形状
    local items = build_youku_search_items({
        { show_id = "s1", title = "剧A", year = 2023, type_name = "电视剧", episode_total = 12 },
        { show_id = "s2", title = "影B", year = "2020", type_name = "电影", episode_total = 1 },
    })
    check("条目数", #items == 2)
    check("条目1形状", items[1].title == "剧A" and items[1].hint == "电视剧 | 2023"
        and items[1].value[3] == "get-yk-event" and items[1].value[4] == "s1"
        and items[1].value[5] == "剧A" and items[1].value[6] == "2023"
        and items[1].value[7] == "电视剧")
    check("空入参安全", #build_youku_search_items({}) == 0)
end

do -- format_episode_title：电影/综艺/剧 三路格式化
    check("电影原标题", yparse.format_episode_title("泰坦尼克号", 1, "电影", "1998-04-03 00:00:00") == "泰坦尼克号")
    check("电影空标题回退", yparse.format_episode_title("", 1, "电影", nil) == "第1集")
    local variety = yparse.format_episode_title("歌手首秀", 3, "综艺", "2024-01-05 20:10:00")
    check("综艺第N期+日期", variety == "第3期 2024-01-05 歌手首秀", variety)
    local variety_named = yparse.format_episode_title("第7期 巅峰对决", 7, "综艺", "2024-02-01 20:00:00")
    check("综艺自带期数不重复", variety_named == "第7期 2024-02-01 巅峰对决", variety_named)
    check("剧第N集", yparse.format_episode_title("知否 05", 5, "电视剧", nil) == "第5集 知否 05")
    check("剧自带集数不重复", yparse.format_episode_title("第5集 知否", 5, "电视剧", nil) == "第5集 知否")
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
