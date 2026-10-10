-- 爱奇艺解析/条目构建单元测试（基于 2026-10 实抓的 tests/fixtures 样本）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local utils = require("mp.utils")
local iparse = require("modules/iqiyi_parse")
require("apis/iqiyi_search") -- build_iqiyi_search_items（全局）；加载仅注册消息

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

do -- link_id_from_url
    check("link_id_from_url", iparse.link_id_from_url("https://www.iqiyi.com/v_abc123.html") == "abc123")
    check("link_id_from_url 无匹配", iparse.link_id_from_url("https://x/y.html") == nil)
    check("link_id_from_url 非串", iparse.link_id_from_url(42) == nil)
end

do -- parse_search：狂飙搜索样本（含完整分集 videos 39 正片 + 1 专访）
    local parsed = iparse.parse_search(read_fixture("iqiyi_search.json"))
    check("搜索 ok", parsed.ok)
    local item = nil
    for _, it in ipairs(parsed.items) do
        if it.title == "狂飙" then item = it break end
    end
    check("狂飙条目存在", item ~= nil)
    check("狂飙条目字段", item ~= nil and item.link_id == "xkt6z3z798"
        and item.year == 2023 and item.type_name == "电视剧")
    check("分集数=39（专访剔除）", item ~= nil and #item.episodes == 39,
        ("got %d"):format(item and #item.episodes or -1))
    check("第1集字段", item ~= nil and item.episodes[1].link_id == "xkt6z3z798"
        and item.episodes[1].number == 1 and item.episodes[1].title == "狂飙第1集")
    check("第39集存在", item ~= nil and item.episodes[39].number == 39)
    local no_doc = true
    for _, it in ipairs(parsed.items) do
        if it.title:find("话题解说", 1, true) then no_doc = false end
    end
    check("原创解说条目被过滤", no_doc)
    check("空入参安全", iparse.parse_search(nil).ok == false)
    check("无 templates", #iparse.parse_search({ data = {} }).items == 0)
end

do -- parse_search：站外/频道过滤 + 分集排序与异常剔除
    local parsed = iparse.parse_search({ data = { templates = {
        { template = 101, albumInfo = { title = "外站剧", siteId = "qq", channel = "电视剧,2",
            pageUrl = "https://www.iqiyi.com/v_out1.html", subtitle = "2024",
            videos = { { number = "1", pageUrl = "https://www.iqiyi.com/v_o1.html", title = "第1集" } } } },
        { template = 101, albumInfo = { title = "正片剧", siteId = "iqiyi", channel = "电视剧,2",
            pageUrl = "https://www.iqiyi.com/v_in1.html", subtitle = "2023",
            videos = {
                { number = "2", pageUrl = "https://www.iqiyi.com/v_in1e2.html", title = "第2集" },
                { number = "专访", pageUrl = "https://www.iqiyi.com/v_iv.html", title = "专访" },
                { number = "1", pageUrl = "https://www.iqiyi.com/v_in1e1.html", title = "第1集" },
                { number = "3", pageUrl = "无链接条目", title = "坏条目" },
            } },        },
        { template = 101, albumInfo = { title = "短剧", siteId = "iqiyi", channel = "短剧,35",
            pageUrl = "https://www.iqiyi.com/v_in2.html", subtitle = "2025" } },
        { template = 125, albumInfo = { title = "推荐组", siteId = "iqiyi", channel = "电视剧,2",
            pageUrl = "https://www.iqiyi.com/v_rec.html", subtitle = "2024" } },
    } } })
    check("站外+短剧+推荐组过滤", #parsed.items == 1)
    local it = parsed.items[1]
    check("分集排序+专访/坏条目剔除", #it.episodes == 2
        and it.episodes[1].number == 1 and it.episodes[1].link_id == "in1e1"
        and it.episodes[2].number == 2 and it.episodes[2].link_id == "in1e2")
    check("total 回退为分集数", it.total == 2)
end

do -- build_iqiyi_search_items：条目形状
    local items = build_iqiyi_search_items({
        { link_id = "abc", title = "剧A", year = 2023, type_name = "电视剧", total = 39 },
    })
    check("条目形状", #items == 1 and items[1].title == "剧A"
        and items[1].hint == "电视剧 | 2023"
        and items[1].value[3] == "get-iq-event" and items[1].value[4] == "abc")
    check("空入参安全", #build_iqiyi_search_items({}) == 0)
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
