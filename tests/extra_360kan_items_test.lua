-- build_360kan_items 单元测试（360kan 搜索响应 → menu_anime 条目）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

require("apis/extra") -- build_360kan_items（全局）；模块加载仅注册消息，无网络

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
    local result = {
        data = {
            longData = {
                rows = {
                    {
                        titleTxt = "测试番剧",
                        cat_name = "动漫",
                        year = "2023",
                        en_id = "111",
                        playlinks = {
                            bilibili1 = "https://www.bilibili.com/bangumi/play/ep1",
                            qq = "https://v.qq.com/x/cover/a/b.html",
                        },
                        seriesPlaylinks = { { url = "https://s/1" }, { url = "https://s/2" } },
                        seriesSite = "bilibili1",
                    },
                    { titleTxt = "无播放链接条目", en_id = "222" },
                    { titleTxt = "无playlinks字段", en_id = "223", playlinks = nil },
                },
            },
        },
    }
    local items = build_360kan_items(result)
    -- rows[1] × 2 个可用站点；无 playlinks 的行跳过（pairs(Source) 顺序不定，按集合断言）
    check("条目数=行×可用站点", #items == 2)
    local by_hint = {}
    for _, it in ipairs(items) do by_hint[it.hint] = it end
    check("b 站行形状", by_hint["动漫 | 2023 | 来源：b 站"] ~= nil
        and by_hint["动漫 | 2023 | 来源：b 站"].title == "测试番剧")
    check("腾讯行形状", by_hint["动漫 | 2023 | 来源：腾讯"] ~= nil)
    local bb = by_hint["动漫 | 2023 | 来源：b 站"]
    check("value 参数序 cat,en_id,playlink,source_id,title,year",
        bb.value[3] == "get-extra-event" and bb.value[4] == "动漫"
        and bb.value[5] == "111"
        and bb.value[6] == "https://www.bilibili.com/bangumi/play/ep1"
        and bb.value[7] == "bilibili1" and bb.value[8] == "测试番剧" and bb.value[9] == "2023")

    check("空响应安全", #build_360kan_items({}) == 0
        and #build_360kan_items({ data = {} }) == 0
        and #build_360kan_items(nil) == 0)
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
