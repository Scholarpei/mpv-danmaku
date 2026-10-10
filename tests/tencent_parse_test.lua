-- tencent_parse 单元测试（自断言，输出 PASS/FAIL 行）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local tp = require("modules/tencent_parse")

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

-- ---------- MbSearch fixtures ----------

local EP_SITES = { { showName = "腾讯视频", totalEpisode = 36 } }

-- MainNeed 命中：广告盒被忽略；year=0 / episodeSites 空被过滤；标题去高亮标签
local MB_SEARCH_MAIN = {
    ret = 0, msg = "",
    data = {
        areaBoxList = {
            {
                boxId = "AdBox",
                itemList = {
                    { doc = { dataType = 1, id = "ad001" },
                      videoInfo = { videoType = 1, typeName = "广告", title = "不应出现",
                                    year = 2024, episodeSites = EP_SITES } },
                },
            },
            {
                boxId = "MainNeed",
                itemList = {
                    { doc = { dataType = 1, id = "mzc00200xx" },
                      videoInfo = { videoType = 2, typeName = "电视剧",
                                    title = '庆<em class="highlight">余年</em> 第二季',
                                    year = 2024, episodeSites = EP_SITES } },
                    { doc = { id = "yearzero" },
                      videoInfo = { videoType = 3, typeName = "动漫", title = "无年份",
                                    year = 0, episodeSites = EP_SITES } },
                    { doc = { id = "noeps" },
                      videoInfo = { videoType = 1, typeName = "电影", title = "无站点",
                                    year = 2021, episodeSites = {} } },
                    { doc = { id = "mzc00200yy" },
                      videoInfo = { videoType = 2, typeName = "电视剧", title = "第二条",
                                    year = 2023, episodeSites = EP_SITES } },
                },
            },
        },
        normalList = {
            itemList = {
                { doc = { id = "normalonly" },
                  videoInfo = { videoType = 2, typeName = "电视剧", title = "不应出现",
                                year = 2022, episodeSites = EP_SITES } },
            },
        },
    },
}

-- 无 MainNeed：回退 normalList；重复 cid 去重
local MB_SEARCH_NORMAL = {
    ret = 0, msg = "",
    data = {
        areaBoxList = { { boxId = "OtherBox", itemList = {} } },
        normalList = {
            itemList = {
                { doc = { id = "dup1" },
                  videoInfo = { videoType = 2, typeName = "电视剧", title = "第一条",
                                year = 2022, episodeSites = EP_SITES } },
                { doc = { id = "dup1" },
                  videoInfo = { videoType = 2, typeName = "电视剧", title = "重复条",
                                year = 2022, episodeSites = EP_SITES } },
                { doc = { id = "solo" },
                  videoInfo = { videoType = 3, typeName = "动漫", title = "只在normalList",
                                year = 2021, episodeSites = EP_SITES } },
            },
        },
    },
}

do
    local r = tp.parse_mb_search(MB_SEARCH_MAIN)
    check("mbsearch MainNeed 命中取2条", r.ok and #r.items == 2)
    check("mbsearch 标题去HTML标签", r.items[1] and r.items[1].title == "庆余年 第二季")
    check("mbsearch 字段抽取", r.items[1].cid == "mzc00200xx" and r.items[1].year == 2024
        and r.items[1].type_name == "电视剧" and r.items[1].video_type == 2)
    check("mbsearch 广告盒/无年份/无站点被过滤", r.items[1].cid ~= "ad001"
        and r.items[1].cid ~= "yearzero" and r.items[1].cid ~= "noeps")

    local r2 = tp.parse_mb_search(MB_SEARCH_NORMAL)
    check("mbsearch normalList 回退+cid去重", r2.ok and #r2.items == 2
        and r2.items[1].cid == "dup1" and r2.items[2].cid == "solo")

    check("mbsearch ret!=0 置失败", tp.parse_mb_search({ ret = 1, msg = "deny" }).ok == false)
    local nodata = tp.parse_mb_search({ ret = 0 })
    check("mbsearch 无data为空成功", nodata.ok and #nodata.items == 0)
    check("mbsearch 非table入参失败", tp.parse_mb_search(nil).ok == false)
    check("mbsearch 空itemList安全", tp.parse_mb_search(
        { ret = "0", data = { normalList = { itemList = {} } } }).ok == true)
end

-- ---------- GetPageData fixtures ----------

local EP_PAGE = {
    ret = 0, msg = "",
    data = {
        has_next_page = false,
        module_list_datas = {
            { module_datas = {
                { module_id = "vsite_episode_list",
                  item_data_lists = { item_datas = {
                      { item_id = "1", item_params = { vid = "v001", cid = "c1", is_trailer = "0",
                          play_title = "1", title = "第一集", union_title = "", image_url = "https://x" } },
                      { item_id = "2", item_params = { vid = "v002", cid = "c1", is_trailer = "1",
                          play_title = "预告", title = "预告", union_title = "", image_url = "https://x" } },
                      { item_id = "3", item_params = { vid = "v003", cid = "c1", is_trailer = "0",
                          play_title = "", title = "", union_title = "第3集(备用)", image_url = "https://x" } },
                  } } },
            } },
        },
    },
}

do
    local r = tp.parse_episode_page(EP_PAGE)
    check("epage 预告被过滤", r.ok and #r.episodes == 2)
    check("epage raw_count为过滤前条数", r.raw_count == 3)
    check("epage play_title优先", r.episodes[1].vid == "v001" and r.episodes[1].title == "1")
    check("epage 标题回退union_title", r.episodes[2].vid == "v003"
        and r.episodes[2].title == "第3集(备用)")
    check("epage has_next_page透传", r.has_next_page == false)

    local more = { ret = 0, data = { has_next_page = true, module_list_datas = EP_PAGE.data.module_list_datas } }
    check("epage has_next_page=true透传", tp.parse_episode_page(more).has_next_page == true)

    check("epage ret!=0置失败", tp.parse_episode_page({ ret = 2, msg = "bad" }).ok == false)
    local empty = tp.parse_episode_page({ ret = 0 })
    check("epage 无data为空成功", empty.ok and #empty.episodes == 0 and empty.raw_count == 0)
    check("epage 缺item_datas安全", tp.parse_episode_page(
        { ret = 0, data = { module_list_datas = { { module_datas = { {} } } } } }).ok == true)
    check("epage 非table入参失败", tp.parse_episode_page(nil).ok == false)
end

-- ---------- parse_barrage_item fixtures ----------

do
    local b1 = tp.parse_barrage_item({
        content = "前方高能",
        time_offset = 12345,
        content_style = '{"color":"ffffff","gradient_colors":["aabbcc","ddeeff"],"position":0}',
    })
    check("barrage 渐变首色优先", b1.color == tonumber("aabbcc", 16))
    check("barrage 毫秒转秒", math.abs(b1.time - 12.345) < 1e-9)
    check("barrage 模式与文本", b1.mode == 1 and b1.text == "前方高能")

    local b2 = tp.parse_barrage_item({
        content = "纯色",
        time_offset = 1000,
        content_style = '{"color":"ff0000"}',
    })
    check("barrage 无渐变取color", b2.color == 0xff0000)

    local b3 = tp.parse_barrage_item({
        content = "带#",
        time_offset = 1000,
        content_style = '{"color":"#00ff00"}',
    })
    check("barrage #前缀色值", b3.color == 0x00ff00)

    local b4 = tp.parse_barrage_item({
        content = "已解码样式",
        time_offset = 1000,
        content_style = { gradient_colors = { "112233", "445566" } },
    })
    check("barrage 样式已是table", b4.color == 0x112233)

    local b5 = tp.parse_barrage_item({ content = "无样式", time_offset = "2000" })
    check("barrage 无样式回退白色", b5.color == 16777215)
    check("barrage time_offset字符串容错", b5.time == 2)

    local b6 = tp.parse_barrage_item({
        content = "坏色值",
        time_offset = 1000,
        content_style = '{"color":"xyz"}',
    })
    check("barrage 非法色值回退白色", b6.color == 16777215)

    check("barrage 非table入参返回nil", tp.parse_barrage_item(nil) == nil)
    check("barrage 缺content为空串", tp.parse_barrage_item({ time_offset = 0 }).text == "")
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
