-- 历史续载须能调用与菜单相同的标题格式化函数；不能因局部函数声明顺序退出脚本。
-- 运行：mpv.com --no-config --idle=once --script=tests/ggl_resume_flow_test.lua
local script_dir = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]")
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path
local utils = require("mp.utils")
local failures = 0
local function check(name, cond, detail)
    print((cond and "PASS " or "FAIL ") .. name .. (detail and (" [" .. tostring(detail) .. "]") or ""))
    if not cond then failures = failures + 1 end
end
local function fixture(name)
    local f = assert(io.open(script_dir .. "/fixtures/" .. name, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

show_message = function() end
set_danmaku_button = function() end
add_source_to_history = function() end
remove_source_from_history = function() end
local history
write_history = function()
    history = { episode = DANMAKU.episode, extra = DANMAKU.extra }
end
require("modules/options")
require("modules/utils")
require("modules/parse")
source_status = require("modules/source_status")
require("modules/menu")
require("apis/dandanplay")
require("apis/ggl_search")
require("sites/ggl")
Sha256 = require("modules/hash")
load_danmaku = function() convert_danmaku_to_ass_events(true) end

-- 只替换网络与磁盘边界：真实 HTML 解析、续载、源登记、弹幕解析及菜单组装均执行。
local pending_reply
call_cmd_async_with_timeout = function(args, timeout, callback)
    pending_reply = callback
end
local cache = require("modules/danmaku_cache")
local payload = fixture("ggl_danmaku.json")
cache.get = function(key)
    if key:match("^ggl:") then return { payload = payload } end
end
local opened
local commandv = mp.commandv
mp.commandv = function(...)
    local args = {...}
    if args[1] == "script-message-to" and args[2] == "uosc" and args[3] == "open-menu" then
        opened = utils.parse_json(args[4])
        return
    end
    return commandv(...)
end

local sibling = { provider = "次元城", data = {
    { time = 10, type = 1, size = 25, color = 16777215, text = "其他源仍正常" },
} }
local function resume(html, gv, src, ep, want_url, want_title)
    DANMAKU = { sources = { ["test://sibling"] = sibling }, count = 1 }
    COMMENTS, history, opened = nil, nil, nil
    source_status.begin({ { key = "extra:ggl", provider = "girigirilove" } })
    resume_ggl_episode({ gv_id = gv, src = src, title = "测试番剧" }, ep)
    -- pcall 仅用于报告失败；生产回调若抛错，mpv 会退出整个弹幕脚本。
    local ok, err = pcall(pending_reply, nil, html)
    check("续载回调不崩溃 " .. gv .. "/" .. ep, ok, not ok and err or nil)
    local loaded = DANMAKU.sources[want_url]
    check("真实弹幕落源 " .. gv .. "/" .. ep, loaded and #loaded.data == 266)
    check("源标题与历史保留真实标签 " .. want_title, loaded
        and loaded.episode_title == want_title and history and history.episode == want_title)
    check("保留其他源并完成渲染管线", DANMAKU.sources["test://sibling"] == sibling
        and COMMENTS and #COMMENTS > 0)
    open_add_total_menu_uosc()
    check("续载后弹幕设置菜单可生成", opened and opened.title == "弹幕设置"
        and #opened.items > 0)
end

resume(fixture("ggl_detail_cold.html"), "27224", 1, 1,
    "https://ani.girigirilove.com/playGV27224-1-1/", "第01集")
resume(fixture("ggl_detail.html"), "26868", 1, 1,
    "https://ani.girigirilove.com/playGV26868-1-1/", "先行01")
resume(fixture("ggl_detail_movie.html"), "27164", 1, 1,
    "https://ani.girigirilove.com/playGV27164-1-1/", "1080P")
-- 原线路缺失时仍按目标集定位到可用线路，标题也必须来自该条目。
resume('<ul class="anthology-list-play"><li><a href="/playGV5-2-3/">03</a></li></ul>',
    "5", 1, 3, "https://ani.girigirilove.com/playGV5-2-3/", "第03集")

for _, case in ipairs({ { html = fixture("ggl_detail_cold.html"), ep = 99 },
    { html = nil, ep = 1 } }) do
    DANMAKU = { sources = { ["test://sibling"] = sibling } }
    history = nil
    source_status.begin({ { key = "extra:ggl", provider = "girigirilove" } })
    resume_ggl_episode({ gv_id = "27224", src = 1, title = "测试番剧" }, case.ep)
    local ok, err = pcall(pending_reply, nil, case.html)
    local entry = source_status.snapshot().entries[1]
    check("无目标/请求失败正常上报", ok and entry and entry.status == "failed", not ok and err or nil)
    check("失败不写历史并保留其他源", history == nil and DANMAKU.sources["test://sibling"] == sibling)
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
os.exit(failures > 0 and 1 or 0)
