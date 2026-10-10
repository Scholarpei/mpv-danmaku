-- 埋堆堆签名/解析/条目构建单元测试（基于 2026-10 实抓的 tests/fixtures 样本 + 确定性签名参考值）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local utils = require("mp.utils")
local mparse = require("modules/maiduidui_parse")
require("apis/maiduidui_search") -- build_maiduidui_search_items（全局）；加载仅注册消息

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

do -- 签名确定性（参考值由 python 独立生成）
    local raw = mparse.raw_data_string({ sactionUuid = "abc", times = 0, vodUuid = "xyz" })
    check("data 串参考值", raw == "sactionUuid=abc&times=0&vodUuid=xyz&", raw)
    local sign = mparse.sign("/api/barrage/vodBarrage396.action",
        { sactionUuid = "abc", times = 0, vodUuid = "xyz" }, 1760000000000)
    check("sign 参考值", sign == "5461fd8410820b4b0af121f13e4c46a0", sign)
    local body = mparse.wrap_body({ keyWord = "法证先锋" }, 1760000000000, "deadbeef")
    check("包裹体形状", body.channel == "1000" and body.os == "Android"
        and body.version == "5.8.00" and body.time == 1760000000000
        and body.sign == "deadbeef" and body.data.keyWord == "法证先锋")
end

do -- parse_search：法证先锋搜索样本（分组 vodList，粤语/国语多版本）
    local parsed = mparse.parse_search(read_fixture("mdd_search.json"))
    check("搜索 ok", parsed.ok)
    check("搜索有条目", #parsed.items >= 5, ("got %d"):format(#parsed.items))
    local found = false
    for _, it in ipairs(parsed.items) do
        if it.name:find("法证先锋", 1, true) then
            found = it.vod_uuid ~= "" and it.total > 0
            break
        end
    end
    check("条目字段", found)
    check("status 异常拒绝", mparse.parse_search({ status = false }).ok == false)
    check("空入参安全", mparse.parse_search(nil).ok == false)
end

do -- parse_sactions：法证先锋分集样本（25 集，name 带 (粤)NN 后缀）
    local parsed = mparse.parse_sactions(read_fixture("mdd_sactions.json"))
    check("分集 ok", parsed.ok)
    check("分集数=25", #parsed.episodes == 25, ("got %d"):format(#parsed.episodes))
    check("第1集字段", parsed.episodes[1].uuid ~= ""
        and parsed.episodes[1].name:find("01", 1, true) ~= nil)
    check("空入参安全", mparse.parse_sactions(nil).ok == false)
end

do -- parse_barrage：第1集弹幕样本（一次请求全量 418 条）
    local comments = mparse.parse_barrage(read_fixture("mdd_barrage.json"))
    check("弹幕条数=418", #comments == 418, ("got %d"):format(#comments))
    check("首条字段", comments[1].time >= 0 and comments[1].color == 16777215
        and comments[1].mode == 1 and comments[1].text ~= "")
    check("彩色弹幕解析", mparse.parse_barrage({ status = true, data = {
        { times = "5", barrageList = {
            { color = "#ff0000", content = "红", times = "5.5" },
            { color = "bad", content = "兜底白", times = "6" },
        } },
    } })[1].color == 16711680)
    check("status 异常拒绝", #mparse.parse_barrage({ status = false }) == 0)
end

do -- build_maiduidui_search_items：条目形状
    local items = build_maiduidui_search_items({
        { vod_uuid = "u1", name = "法证先锋(粤)", material_name = "警匪", total = 25 },
    })
    check("条目形状", #items == 1 and items[1].title == "法证先锋(粤)"
        and items[1].hint == "警匪 | 25集"
        and items[1].value[3] == "get-mdd-event" and items[1].value[4] == "u1")
    check("空入参安全", #build_maiduidui_search_items({}) == 0)
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
