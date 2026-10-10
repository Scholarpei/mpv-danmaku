-- 巴哈姆特解析/条目构建单元测试（搜索样本实抓；分集样本为接口形态构造——
-- video.php 的 anime 数据段对大陆直连 IP 受限无法实抓）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local utils = require("mp.utils")
local bparse = require("modules/bahamut_parse")
require("apis/bahamut_search") -- build_bahamut_search_items（全局）；加载仅注册消息

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

do -- parse_search：芙莉莲搜索样本（顶层 anime[]，繁体标题）
    local parsed = bparse.parse_search(read_fixture("baha_search.json"))
    check("搜索 ok", parsed.ok)
    check("搜索有条目", #parsed.items >= 1)
    local it = parsed.items[1]
    check("条目1字段", it ~= nil and it.video_sn ~= "" and it.title ~= ""
        and it.year >= 2020, tostring(it and it.year))
    check("空入参安全", bparse.parse_search(nil).ok == false)
    check("无 anime 响应", bparse.parse_search({}).ok == true
        and #bparse.parse_search({}).items == 0)
end

do -- parse_search：info 年份解析与去重
    local parsed = bparse.parse_search({ anime = {
        { video_sn = 100, title = "劇A", info = "年份：2023/10 共 12 集" },
        { video_sn = 100, title = "劇A重复", info = "" },
        { video_sn = 101, title = "劇B", info = "年份：2024/01" },
    } })
    check("年份解析+去重", #parsed.items == 2
        and parsed.items[1].year == 2023 and parsed.items[2].year == 2024)
end

do -- parse_video_info：分集结构（对象 episodes 取 "0" 键）
    local parsed = bparse.parse_video_info({ data = { data = { anime = {
        title = "某動畫",
        episodes = {
            ["0"] = {
                { episode = 1, videoSn = 111 },
                { episode = 2, videoSn = 222 },
            },
            ["1"] = { { episode = 1, videoSn = 999 } },
        },
    } } } })
    check("分集 ok", parsed.ok)
    check("取键0", #parsed.episodes == 2
        and parsed.episodes[1].video_sn == "111" and parsed.episodes[2].video_sn == "222")
end

do -- parse_video_info：受限/异常结构（各层断层均按受限识别，杜绝 ok=true 空表漏到菜单）
    local restricted = bparse.parse_video_info({ data = { data = { video = {}, anime = {} } } })
    check("受限识别（anime 空）", restricted.ok == false and restricted.restricted == true)
    local cut2 = bparse.parse_video_info({ data = {} })
    check("受限识别（data.data 断层）", cut2.ok == false and cut2.restricted == true)
    local cut1 = bparse.parse_video_info({})
    check("受限识别（data 断层）", cut1.ok == false and cut1.restricted == true)
    check("空入参安全", bparse.parse_video_info(nil).ok == false)
    local noeps = bparse.parse_video_info({ data = { data = { anime = { episodes = {} } } } })
    check("空分集拒绝", noeps.ok == false and noeps.restricted == true)
end

do -- parse_video_info：单层深度形态（{data:{video,anime}}，实测间歇出现）
    local single = bparse.parse_video_info({ data = { anime = {
        title = "某動畫",
        episodes = { ["0"] = { { episode = 1, videoSn = 11 }, { episode = 2, videoSn = 22 } } },
    } } })
    check("单层形态解析", single.ok == true and #single.episodes == 2
        and single.episodes[1].video_sn == "11")
    -- 真实窗口期样本（单层形态，芙莉莲 S2 29-38 话）
    local real = bparse.parse_video_info(read_fixture("baha_video_full.json"))
    check("真实单层样本", real.ok == true and #real.episodes == 10
        and real.episodes[1].episode == 29 and real.episodes[10].episode == 38,
        ("got %d"):format(#real.episodes))
end

do -- build_bahamut_search_items：条目形状
    local items = build_bahamut_search_items({
        { video_sn = "47221", title = "葬送的芙莉蓮 第二季", year = 2026 },
    })
    check("条目形状", #items == 1 and items[1].title == "葬送的芙莉蓮 第二季"
        and items[1].hint == "动画疯 | 2026"
        and items[1].value[3] == "get-baha-event" and items[1].value[4] == "47221")
    check("空入参安全", #build_bahamut_search_items({}) == 0)
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
