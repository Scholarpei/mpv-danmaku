-- B站 WBI 签名/解析/条目构建单元测试（基于 2026-10 实抓的 tests/fixtures 样本 + 确定性签名参考值）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local utils = require("mp.utils")
local bw = require("modules/bilibili_wbi")
require("apis/bilibili_search") -- build_bilibili_search_items（全局）；加载仅注册消息

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

do -- mixin_key / key_from_url / parse_nav（参考值由 python 独立生成）
    local mixin = bw.mixin_key("7cd084941338484aae1ad9425b84077c", "4932caff0ff746eab6f01bf08b70ac45")
    check("mixin_key 参考值", mixin == "ea1db124af3c7062474693fa704f4ff8", mixin)
    check("key_from_url", bw.key_from_url("https://i0.hdslb.com/bfs/wbi/7cd08494.png")
        == "7cd08494")
    check("key_from_url 无扩展名", bw.key_from_url("https://x/y") == nil)
    local nav_mixin = bw.parse_nav(read_fixture("bili_nav.json"))
    check("parse_nav 与参考一致", nav_mixin == mixin, nav_mixin)
    check("parse_nav 空响应", bw.parse_nav({}) == nil)
end

do -- encodeURIComponent / signed_query（wts=1760000000 确定性断言）
    check("bw:encode_uri_component 保留!'()*", bw.encode_uri_component("a!b'c(d)*e") == "a!b'c(d)*e")
    check("encodeURIComponent 空格与中文", bw.encode_uri_component("测 x")
        == "%E6%B5%8B%20x", bw.encode_uri_component("测 x"))
    local qs = bw.signed_query({
        keyword = "测试 key!（安全）",
        search_type = "media_bangumi",
        page = "1",
    }, "ea1db124af3c7062474693fa704f4ff8", 1760000000)
    check("signed_query 参考值", qs ==
        "keyword=%E6%B5%8B%E8%AF%95%20key!%EF%BC%88%E5%AE%89%E5%85%A8%EF%BC%89&page=1&search_type=media_bangumi&wts=1760000000&w_rid=1213dac02b2f23b81f6b4f747d249606",
        qs)
end

do -- parse_search：芙莉莲搜索样本（中配版+原版 2 条，title 带 <em> 高亮）
    local parsed = bw.parse_search(read_fixture("bili_search.json"))
    check("搜索 ok", parsed.ok)
    check("搜索条目数=2", #parsed.items == 2)
    local it = parsed.items[1]
    check("条目1字段", it ~= nil and it.season_id ~= ""
        and it.title == "葬送的芙莉莲 中配版"
        and it.type_name == "番剧" and it.index_show == "全28话")
    check("年份来自 pubtime", it.year == 2025, tostring(it and it.year))
    check("code 非 0 拒绝", bw.parse_search({ code = -412 }).ok == false)
    check("空入参安全", bw.parse_search(nil).ok == false)
    check("空 result", #bw.parse_search({ code = 0, data = {} }).items == 0)
end

do -- parse_season：芙莉莲 season 样本（46 条含预告，正片 section_type==0 共 28 条）
    local parsed = bw.parse_season(read_fixture("bili_season.json"))
    check("分集 ok", parsed.ok)
    check("标题", parsed.title == "葬送的芙莉莲")
    check("正片数=28", #parsed.episodes == 28, ("got %d"):format(#parsed.episodes))
    check("第1话字段", parsed.episodes[1].ep_id == "779775"
        and parsed.episodes[1].cid ~= "" and parsed.episodes[1].long_title == "冒险的结束")
    check("第28话存在", parsed.episodes[28].ep_id == "819062")
    check("code 非 0 拒绝", bw.parse_season({ code = -404 }).ok == false)
end

do -- build_bilibili_search_items：season_id 去重 + hint 组装
    local items = build_bilibili_search_items({
        { season_id = "100", title = "番A", org_title = "アニメA", year = 2023, type_name = "番剧", index_show = "全12话" },
        { season_id = "100", title = "番A重复", org_title = "", year = 2023, type_name = "番剧", index_show = "" },
        { season_id = "200", title = "番B", org_title = "", year = 0, type_name = "番剧", index_show = "" },
    })
    check("去重后条目数=2", #items == 2)
    check("条目1形状", items[1].title == "番A / アニメA"
        and items[1].hint == "番剧 | 2023 | 全12话"
        and items[1].value[3] == "get-bili-event" and items[1].value[4] == "100")
    check("条目2无年份0省略index_show", items[2].hint == "番剧 | 0"
        and items[2].title == "番B")
    check("空入参安全", #build_bilibili_search_items({}) == 0)
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
