-- 弹幕源统计菜单单元测试（modules/menu.lua：build_source_stats_items 纯函数 +
-- 打开/原地刷新链路）：
-- 台账∪源表合并（未入台账源合成 done 行）、汇总计数、排序稳定性（键不含 status，
-- 状态迁移不重排）、逐源行字形/hint、详情子行（完整 URL/延迟/时间轴校正/错误全文/
-- 屏蔽）、管线区两态、空态、菜单开着时台账变异触发 update-menu 原地刷新（行数与
-- key 序不变）、未开着零消息
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local utils = require("mp.utils")

-- ---- 打桩（require 前置；模块运行时按全局查找这些名字）----
local stub = { msgs = {} }
show_message = function(text, time) stub.msgs[#stub.msgs + 1] = tostring(text) end
load_danmaku = function() end
add_source_to_history = function() end
write_history = function() end
DANMAKU = { sources = {}, count = 1 }
-- 台账真模块须在 menu.lua 之前注入全局（menu.lua 加载尾部的 set_on_change 挂钩
-- 按全局类型检测；main.lua 同序——source_status(13) 先于 menu）
source_status = require("modules/source_status")

require("modules/options")
require("modules/utils")
require("modules/parse")
local observed = {}
local real_observe = mp.observe_property
mp.observe_property = function(name, kind, fn)
    observed[name] = fn
    return real_observe(name, kind, fn)
end
require("modules/menu")

-- 模拟 uosc 环境（menu.lua 加载时检测为 false，需在其后覆盖）
uosc_available = true

-- 捕获发往 uosc 的菜单命令
local sent = {}
local real_commandv = mp.commandv
mp.commandv = function(...)
    local args = { ... }
    if args[1] == "script-message-to" and args[2] == "uosc"
        and (args[3] == "open-menu" or args[3] == "update-menu" or args[3] == "close-menu") then
        sent[#sent + 1] = { cmd = args[3], json = args[4] }
    end
    return real_commandv(...)
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

local function find_detail(details, prefix)
    for _, row in ipairs(details) do
        if row.title:sub(1, #prefix) == prefix then return row.title end
    end
    return nil
end

-- ---- build_source_stats_items 纯函数 ----

local ENTRIES = {
    { key = "https://a.qq.com/1", provider = "腾讯视频", anime = "番A", episode = "第1集",
      status = "done", count = 120 },
    { key = "https://b.ezdmw.org/2", provider = "ezdmw", anime = "番B", episode = "第2集",
      status = "empty", error = "该集无弹幕资源（E站未绑定弹幕播放器）" },
    { key = "https://c.acfun.cn/3", provider = "AcFun", anime = "番C",
      status = "failed", error = "网络失败：curl exit 6" },
    { key = "https://d.girigirilove.com/4", provider = "girigirilove", anime = "番D",
      status = "pending", error = "直连失败（播放页解析失败）" },
}
local SOURCES = {
    ["https://a.qq.com/1"] = {
        from = "user_custom", provider = "腾讯视频", anime_title = "番A", episode_title = "第1集",
        data = { 1 }, delay_segments = { { start = 0, delay = 2.5 } }, align_shift = -3,
    },
    ["https://e.bilibili.com/5"] = {
        from = "user_custom", provider = "bilibili", anime_title = "番E", episode_title = "P2",
        data = { 1, 2, 3 }, from_history = true, blocked = true,
    },
}

do -- 合并 + 计数 + 排序（provider..url：AcFun < bilibili < ezdmw < girigirilove < 腾讯）
    local items = build_source_stats_items(ENTRIES, SOURCES,
        { merge = { before = 100, after = 60 }, total = 58 })
    check("汇总行", items[1].title == "源统计（共 5 个）", items[1].title)
    check("计数行", items[2].title == "  成功 2 · 无数据 1 · 失败 1 · 等待 1", items[2].title)
    check("合并管线行", items[3].title == "  已合并 40 条相似弹幕（100→60）", items[3].title)
    check("渲染管线行", items[4].title == "  最终渲染 58 条", items[4].title)
    -- 逐源行 [5..9]：failed / 合成done / empty / pending / done
    check("failed行字形", items[5].title == "✗ AcFun《番C》", items[5].title)
    check("合成done行（未入台账源）", items[6].title == "✓ bilibili《番E》P2", items[6].title)
    check("empty行", items[7].title == "○ ezdmw《番B》第2集", items[7].title)
    check("pending行", items[8].title == "… girigirilove《番D》", items[8].title)
    check("done行", items[9].title == "✓ 腾讯视频《番A》第1集", items[9].title)
    -- hint：条数 · 来源标签（记忆/未落源/缓存后缀） · 状态词
    check("done行hint", items[9].hint == "120条 · 用户添加 · 成功 · 时长未知", items[9].hint)
    check("合成行hint（记忆+屏蔽）", items[6].hint == "3条 · 用户添加（记忆） · 成功 · 时长未知", items[6].hint)
    check("empty行hint（未落源）", items[7].hint == "— · 未落源 · 无数据 · 时长未知", items[7].hint)
    check("pending行hint", items[8].hint == "— · 未落源 · 等待中 · 时长未知", items[8].hint)
    -- 逐源行可选中展开详情（嵌套 items），汇总/管线行不可选
    check("逐源行可选中", items[5].selectable == true and items[6].selectable == true)
    check("汇总行不可选", items[1].selectable == false and items[2].selectable == false)
    check("逐源行带详情子菜单", type(items[5].items) == "table" and #items[5].items > 0)
end

do -- 详情子行：完整 URL / 延迟 / 时间轴校正 / 错误全文 / 屏蔽 / 缓存来源
    local items = build_source_stats_items(ENTRIES, SOURCES, { total = 1 })
    local base = 3  -- total 恒显占一行（无 merge 行）
    local d_done = items[base + 5].items
    check("详情含完整URL", find_detail(d_done, "URL：") == "URL：https://a.qq.com/1",
        find_detail(d_done, "URL："))
    check("详情手动延迟", find_detail(d_done, "手动延迟：") == "手动延迟：+2.5 秒",
        find_detail(d_done, "手动延迟："))
    check("详情时间轴校正", find_detail(d_done, "时间轴校正：") == "时间轴校正：-3.00 秒",
        find_detail(d_done, "时间轴校正："))
    check("详情屏蔽否", find_detail(d_done, "屏蔽：") == "屏蔽：否")
    check("详情缓存来源未标注", find_detail(d_done, "缓存来源：") == "缓存来源：网络获取（未标注缓存命中）")
    local d_failed = items[base + 1].items
    check("failed详情错误全文",
        find_detail(d_failed, "错误信息：") == "错误信息：网络失败：curl exit 6",
        find_detail(d_failed, "错误信息："))
    local d_empty = items[base + 3].items
    check("empty详情无数据原因",
        find_detail(d_empty, "无数据原因：") == "无数据原因：该集无弹幕资源（E站未绑定弹幕播放器）",
        find_detail(d_empty, "无数据原因："))
    local d_pending = items[base + 4].items
    check("pending详情进行中备注",
        find_detail(d_pending, "进行中备注：") == "进行中备注：直连失败（播放页解析失败）",
        find_detail(d_pending, "进行中备注："))
    local d_synth = items[base + 2].items
    check("合成行详情屏蔽是", find_detail(d_synth, "屏蔽：") == "屏蔽：是（未参与渲染）")
    check("done详情无错误行", find_detail(d_done, "错误信息：") == nil
        and find_detail(d_done, "无数据原因：") == nil)
end

do -- 缓存标注后缀 + 缓存来源词
    local entries2 = {}
    for _, e in ipairs(ENTRIES) do entries2[#entries2 + 1] = e end
    entries2[1].cache = "cache"    -- done + 磁盘缓存
    entries2[4].cache = "stale"    -- pending + 离线缓存（理论上 stale 必伴随数据，防御性验证）
    local items = build_source_stats_items(entries2, SOURCES, nil)
    -- 无管线行：[1]汇总 [2]计数，行序 acfun[3] bilibili[4] ezdmw[5] ggl[6] qq[7]
    check("缓存后缀hint", items[7].hint == "120条 · 用户添加 ·缓存 · 成功 · 时长未知", items[7].hint)
    check("离线缓存后缀hint", items[6].hint == "— · 未落源 ·离线缓存 · 等待中 · 时长未知", items[6].hint)
    check("缓存来源词", find_detail(items[7].items, "缓存来源：") == "缓存来源：磁盘缓存（TTL 内命中）")
end

do -- 排序稳定性：状态迁移（failed→done）不重排（update-menu 按索引保留选中/滚动）
    local a = build_source_stats_items(ENTRIES, SOURCES, nil)
    local entries2 = {}
    for _, e in ipairs(ENTRIES) do
        entries2[#entries2 + 1] = e
        if e.status == "failed" then e.status = "done"; e.count = 7 end
    end
    -- 上面原地改了 ENTRIES（浅引用），两次构建共用同表——第一次已取回 items，直接重建
    local b = build_source_stats_items(entries2, SOURCES, nil)
    local base = 2
    local keys_a, keys_b = {}, {}
    for i = 1, 5 do
        keys_a[i] = find_detail(a[base + i].items, "URL：")
        keys_b[i] = find_detail(b[base + i].items, "URL：")
    end
    check("状态迁移不重排", table.concat(keys_a, "|") == table.concat(keys_b, "|"),
        table.concat(keys_b, "|"))
    check("迁移后字形变化", b[base + 1].title:find("✓ AcFun", 1, true) ~= nil, b[base + 1].title)
    -- 还原 ENTRIES 供后续用例
    for _, e in ipairs(ENTRIES) do
        if e.key == "https://c.acfun.cn/3" then e.status = "failed"; e.count = nil end
    end
end

do -- 管线区两态：无 merge/黑名单/密度值时不出现行；黑名单/密度有值时出现
    local items = build_source_stats_items(ENTRIES, SOURCES, nil)
    check("无管线行", items[3].selectable == true, items[3].title)  -- 第 3 行已是逐源行
    local items2 = build_source_stats_items(ENTRIES, SOURCES,
        { merge = { before = 10, after = 10 }, blacklist = { dropped = 4 },
          density = { shrunk = 2, dropped = 1 } })
    check("merge相等不出行", items2[3].title:find("已合并") == nil, items2[3].title)
    check("黑名单行", items2[3].title == "  黑名单：过滤 4 条", items2[3].title)
    check("密度行", items2[4].title == "  智能密度：缩小 2 条，丢弃 1 条", items2[4].title)
end

do -- 空态
    local items = build_source_stats_items({}, {}, nil)
    check("空态单行", #items == 1 and items[1].title == "当前视频暂无弹幕源记录"
        and items[1].selectable == false and items[1].align == "center", items[1].title)
end

-- ---- 打开 / 原地刷新链路 ----

do -- 打开菜单：open-menu + menu_stats + 台账数据渲染
    DANMAKU.sources = {}
    source_status.reset()
    source_status.ensure("https://r.qq.com/1", "腾讯视频", { anime = "实番", episode = "第1集" })
    mp.set_property_native("user-data/uosc/menu/type", "menu_total")
    local n = #sent
    open_source_stats_menu_uosc()
    check("打开发open-menu", #sent == n + 1 and sent[#sent].cmd == "open-menu", sent[#sent] and sent[#sent].cmd)
    local props = utils.parse_json(sent[#sent].json)
    check("菜单类型", props.type == "menu_stats", props.type)
    check("禁用搜索", props.search_style == "disabled")
    check("等待行渲染", props.items[2].title:find("等待 1") ~= nil, props.items[2].title)
end

do -- 菜单开着时台账变异 → update-menu 原地刷新，行数与 key 序不变
    mp.set_property_native("user-data/uosc/menu/type", "menu_stats")
    local n = #sent
    -- 数据落源 + mark_done（变异通知 → refresh_source_stats_menu）
    DANMAKU.sources["https://r.qq.com/1"] = {
        from = "user_custom", provider = "腾讯视频", anime_title = "实番",
        episode_title = "第1集", data = { 1, 2, 3 },
    }
    source_status.mark_done("https://r.qq.com/1", { count = 3 })
    check("变异触发update-menu", #sent == n + 1 and sent[#sent].cmd == "update-menu",
        sent[#sent] and sent[#sent].cmd)
    local props = utils.parse_json(sent[#sent].json)
    check("刷新后计数", props.items[2].title == "  成功 1 · 无数据 0 · 失败 0 · 等待 0",
        props.items[2].title)
    check("刷新行数稳定（2 头行 + 1 源行）", #props.items == 3, #props.items)
    -- remove（源删除联动）同样触发刷新且行收缩（真实删除流程会同时清
    -- DANMAKU.sources——台账 remove 后源表残留数据会以合成 done 行呈现，如实反映）
    n = #sent
    DANMAKU.sources["https://r.qq.com/1"] = nil
    source_status.remove("https://r.qq.com/1")
    check("remove触发update-menu", #sent == n + 1 and sent[#sent].cmd == "update-menu")
    props = utils.parse_json(sent[#sent].json)
    check("remove后空态", props.items[1].title == "当前视频暂无弹幕源记录", props.items[1].title)
end

do -- 菜单未开（其他菜单/无菜单）时台账变异零消息
    mp.set_property_native("user-data/uosc/menu/type", "menu_total")
    local n = #sent
    source_status.ensure("https://r2.qq.com/2", "腾讯视频", { anime = "另一番" })
    source_status.mark_failed("https://r2.qq.com/2", "网络失败", "腾讯视频")
    check("未开菜单零消息", #sent == n, #sent - n)
    mp.set_property_native("user-data/uosc/menu/type", nil)
    n = #sent
    source_status.mark_failed("https://r2.qq.com/2", "再次失败", "腾讯视频")
    check("无菜单属性零消息", #sent == n, #sent - n)
end

do -- 无 uosc 回退：OSD dump
    uosc_available = false
    stub.msgs = {}
    show_source_stats_osd()
    check("回退OSD有内容", #stub.msgs > 0 and stub.msgs[#stub.msgs]:find("弹幕") ~= nil,
        stub.msgs[#stub.msgs])
    uosc_available = true
end


-- Duration comparisons must use the matched video, with source minus mpv direction.
do
    local cases = {
        { 1445, 1440, "24:05（+5秒）" },
        { 1435, 1440, "23:55（-5秒）" },
        { 1440, 1440, "24:00（0秒）" },
        { 1440.1, 1440.4, "24:00（0秒）" },
        { 3661, 3600, "1:01:01（+61秒）" },
    }
    for i, c in ipairs(cases) do
        local items = build_source_stats_items({{key="duration-test", status="done",
            duration_seconds=c[1]}}, {}, nil, c[2])
        local row = items[#items]
        check("时长差方向/格式 " .. i, row.hint:find(c[3], 1, true) ~= nil, row.hint)
        check("详情源视频时长 " .. i, find_detail(row.items, "源视频时长：") ~= nil)
        check("详情当前视频时长 " .. i, find_detail(row.items, "当前视频时长：") ~= nil)
        check("详情差值方向 " .. i, (find_detail(row.items, "时长差：") or ""):find("源视频 − 当前视频", 1, true) ~= nil)
    end
    local items = build_source_stats_items({}, {x={data={1},duration_seconds=1445}}, nil, 1440)
    check("未入台账源时长", items[#items].hint:find("+5秒",1,true) ~= nil)
    for _, bad in ipairs({0,-1,math.huge,0/0}) do
        items = build_source_stats_items({{key="x",duration_seconds=bad}}, {}, nil, 1440)
        check("非法源时长未知", items[#items].hint:find("时长未知",1,true) ~= nil)
    end
    items = build_source_stats_items({{key="x",duration_seconds=1445}}, {}, nil, nil)
    check("mpv未知仍显示源时长", items[#items].hint:find("24:05",1,true) ~= nil)
    check("mpv未知不计算差值", find_detail(items[#items].items,"时长差：") == "时长差：无法比较")
end


do -- A late mpv duration must update the comparison without moving source rows.
    source_status.reset()
    DANMAKU.sources={x={data={1},duration_seconds=1445}}
    source_status.ensure("x","test")
    mp.set_property_native("user-data/uosc/menu/type","menu_stats")
    local real_number=mp.get_property_number
    local current=nil
    mp.get_property_number=function(name, fallback)
        if name=="duration" then return current end
        return real_number(name,fallback)
    end
    refresh_source_stats_menu()
    local before=utils.parse_json(sent[#sent].json)
    current=1440
    observed.duration("duration",current)
    local after=utils.parse_json(sent[#sent].json)
    check("mpv时长迟到刷新差值",after.items[#after.items].hint:find("+5秒",1,true)~=nil)
    check("mpv时长迟到不插入行",#before.items==#after.items)
    check("顶部显示当前时长",after.items[1].hint=="当前视频时长：24:00")
    mp.get_property_number=real_number
    mp.set_property_native("user-data/uosc/menu/type",nil)
end

do
    local info={reference_seconds=1470,reason="Bangumi 目录参考时长，并非源视频实测"}
    local items=build_source_stats_items({{key="catalog",status="done"}}, {}, nil,1452.65,nil,{catalog=info})
    local row=items[#items]
    check("目录参考在源行明确标注",row.hint:find("参考 24:30（+17秒）",1,true)~=nil,row.hint)
    check("目录参考不冒充实测",find_detail(row.items,"源视频时长：")=="源视频时长：时长未知")
    check("目录参考单独详情",find_detail(row.items,"目录参考时长：")=="目录参考时长：24:30")
    check("参考差值另行标注",find_detail(row.items,"参考时长差：")=="参考时长差：+17秒（目录参考 − 当前视频）")
    check("来源或未知原因详情",find_detail(row.items,"时长说明：")=="时长说明："..info.reason)
end
if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
