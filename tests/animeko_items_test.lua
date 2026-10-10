-- animeko 解析/条目构建单元测试（基于 2026-10 实抓的 tests/fixtures 样本）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local utils = require("mp.utils")
local aparse = require("modules/animeko_parse")
require("apis/animeko_search") -- build_animeko_search_items（全局）；加载仅注册消息

local function read_fixture(name)
    local path = script_dir .. "/fixtures/" .. name
    local f = assert(io.open(path, "rb"))
    local content = f:read("*all")
    f:close()
    return assert(utils.parse_json(content), "fixture 解析失败: " .. name)
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

do -- parse_search：芙莉莲 bgm 搜索样本（5 条，name_cn 优先）
    local parsed = aparse.parse_search(read_fixture("ako_search.json"))
    check("搜索 ok", parsed.ok)
    check("搜索条目数=5", #parsed.items == 5)
    check("条目1字段", parsed.items[1].subject_id == "400602"
        and parsed.items[1].title == "葬送的芙莉莲" and parsed.items[1].year == 2023)
    check("空入参安全", aparse.parse_search(nil).ok == true
        and #aparse.parse_search(nil).items == 0)
end

do -- parse_subject：芙莉莲 S1 样本（36 条含 ED/OP，MAIN 正片 28 条）
    local parsed = aparse.parse_subject(read_fixture("ako_subject.json"))
    check("分集 ok", parsed.ok)
    check("标题 nameCn 优先", parsed.title ~= "")
    check("MAIN 正片数=28", #parsed.episodes == 28, ("got %d"):format(#parsed.episodes))
    check("第1话字段", parsed.episodes[1].episode_id == "1227087"
        and parsed.episodes[1].title == "冒险结束")
    check("空入参安全", aparse.parse_subject(nil).ok == false)
end

do -- parse_danmaku_list：芙莉莲 S1E1 弹幕样本（顶层 danmakuList 80 条）
    local comments = aparse.parse_danmaku_list(read_fixture("ako_danmaku.json"))
    check("弹幕条数=80", #comments == 80, ("got %d"):format(#comments))
    check("首条字段", comments[1].time > 200 and comments[1].mode == 1
        and comments[1].color == 16777215 and comments[1].text ~= "")
    check("TOP/BOTTOM 映射", aparse.parse_danmaku_list({ danmakuList = {
        { danmakuInfo = { playTime = 1000, location = "TOP", color = -1, text = "a" } },
        { danmakuInfo = { playTime = 2000, location = "BOTTOM", color = 16711680, text = "b" } },
        { danmakuInfo = { playTime = 3000, location = "NORMAL", color = -1, text = "c" } },
    } })[1].mode == 5)
    check("空入参安全", #aparse.parse_danmaku_list({}) == 0)
end

do -- build_animeko_search_items：条目形状（接收原始响应文本）
    local items = build_animeko_search_items(utils.format_json({
        data = {
            { id = 100, name_cn = "番A", date = "2023-10-01" },
            { id = 200, name = "番B" },
        },
    }))
    check("条目数", #items == 2)
    check("条目1形状", items[1].title == "番A" and items[1].hint == "番剧 | 2023"
        and items[1].value[3] == "get-ako-event" and items[1].value[4] == "100")
    check("空入参安全", #build_animeko_search_items(utils.format_json({})) == 0)
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
