-- build_tencent_search_items 单元测试（MbSearch 解析结果 → menu_anime 条目）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

require("apis/tencent_search") -- build_tencent_search_items（全局）；加载仅注册消息

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
    local parsed = {
        { cid = "c1", title = "番剧A", year = 2023, type_name = "动漫", video_type = 2 },
        { cid = "c2", title = "电影B", year = "2020", type_name = "电影" }, -- video_type 缺失 → ""
    }
    local items = build_tencent_search_items(parsed)
    check("条目数", #items == 2)
    check("条目1形状", items[1].title == "番剧A" and items[1].hint == "动漫 | 2023"
        and items[1].value[3] == "get-tx-event" and items[1].value[4] == "c1"
        and items[1].value[5] == "番剧A" and items[1].value[6] == "2023"
        and items[1].value[7] == "动漫" and items[1].value[8] == "2")
    check("条目2 video_type 缺失回退空串", items[2].value[8] == ""
        and items[2].hint == "电影 | 2020")
    check("空入参安全", #build_tencent_search_items({}) == 0)
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
