-- build_maccms_items 单元测试（采集站搜索命中 → menu_anime 条目，含 remarks 集数标注）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

require("apis/maccms") -- build_maccms_items（全局）；加载仅注册消息

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

do
    local found = {
        { server = "https://www.caiji1.com", entry = {
            vod_id = 101, vod_name = "番剧A", vod_year = 2023,
            vod_class = "国产动漫", remarks = "全24集",
            play = { from = { "qq" } },
        } },
        { server = "https://caiji2.net", entry = {
            vod_id = 102, vod_name = "番剧B", vod_year = 0,
            vod_class = "", remarks = "",
            play = { from = { "m3u8" } },
        } },
    }
    local items = build_maccms_items(found)
    check("条目数", #items == 2)
    check("条目1 hint 年份|分类|host|remarks（host 去-www）",
        items[1].title == "番剧A" and items[1].hint == "2023|国产动漫|caiji1.com|全24集")
    check("条目1 value", items[1].value[3] == "get-maccms-event"
        and items[1].value[4] == "https://www.caiji1.com" and items[1].value[5] == "101")
    check("条目2 缺年份/分类/remarks 的省略",
        items[2].hint == "?|caiji2.net" and items[2].value[5] == "102")
    check("空入参安全", #build_maccms_items({}) == 0)
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
