-- search_hub 编排流测试（stub 各源 fetch 与菜单渲染，步进验证聚合/超时/取消/备注过滤）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local hub = require("modules/search_hub")
require("modules/utils") -- get_api_server_list 等

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

-- ===== 全局 stub（hub 在调用时读取这些全局） =====

options = {
    api_server = "https://a.example|主, https://b.example",
    maccms_servers = "",
    tmdb_api_key = "",
    proxy = "",
}
uosc_available = true
latest_menu_anime = nil
is_chinese = function(s) return true end
url_encode = function(s) return s end

local msgs = {}
show_message = function(text, t) msgs[#msgs + 1] = text end

local menu_calls = {}
update_menu_uosc = function(menu_type, menu_title, menu_item, menu_footnote, menu_cmd, query, message_icon, on_close)
    menu_calls[#menu_calls + 1] = {
        menu_type = menu_type, title = menu_title, item = menu_item,
        footnote = menu_footnote, cmd = menu_cmd, query = query,
        icon = message_icon, on_close = on_close,
    }
    return "json#" .. #menu_calls
end

local active_cancel, active_type
set_active_request = function(cancel_fn, menu_type)
    active_cancel = cancel_fn
    active_type = menu_type
end

local tx_deferred = {}
local fetch_calls = {}
fetch_tencent_search = function(query, cb, timeout)
    fetch_calls.tencent = { query = query, timeout = timeout }
    local entry = { cb = cb, cancelled = false,
        cancel = function(self) self.cancelled = true end }
    tx_deferred[#tx_deferred + 1] = entry
    return function() entry.cancelled = true end
end
fetch_360kan_search = function(query, class, cb, timeout)
    fetch_calls.kan360 = { query = query, class = class, timeout = timeout }
    cb({ { title = "K1", hint = "动漫 | 2023 | 来源：b 站", value = { "k" } } }, nil)
    return function() end
end
fetch_maccms_found = function(name, cb, opts)
    fetch_calls.maccms = { name = name, opts = opts }
    cb({}, false)
    return function() end
end

local pr_servers_log = {}
parallel_requests = function(servers, build_args_fn, per_cb, final_cb, opts)
    pr_servers_log[#pr_servers_log + 1] = servers
    for _, srv in ipairs(servers) do
        per_cb(srv, nil,
            '{"animes":[{"animeTitle":"D1","bangumiId":1001,"typeDescription":"TV动画"}]}')
    end
    final_cb()
    return function() end
end

build_dandanplay_menu_item = function(anime, server, note)
    return {
        title = anime.animeTitle .. "@" .. server,
        hint = anime.typeDescription .. (note and ("|" .. note) or ""),
        value = { "d", server, anime.bangumiId },
    }
end

-- ===== 步进场景 =====

local steps = {}

-- 场景1：dandan/360kan 同步完成、腾讯挂起再触发 → 终版分组渲染
steps[#steps + 1] = function()
    menu_calls = {}
    hub.multi_source_search("测试番剧", nil)

    local last = menu_calls[#menu_calls]
    check("S1 等待期为 spinner 进度行", type(last.item) == "table"
        and last.item[1] ~= nil and last.item[1].icon == "spinner"
        and last.item[1].selectable == false)
    check("S1 等待期渲染带 on_close（第8参）", last.on_close ~= nil)
    check("S1 已注册取消", active_cancel ~= nil and active_type == "menu_anime")
    check("S1 fetch 参数（腾讯/360kan 用原名、9s 超时）",
        fetch_calls.tencent ~= nil and fetch_calls.tencent.query == "测试番剧"
        and fetch_calls.tencent.timeout == hub.PER_SOURCE_TIMEOUT
        and fetch_calls.kan360 ~= nil and fetch_calls.kan360.query == "测试番剧"
        and fetch_calls.kan360.timeout == hub.PER_SOURCE_TIMEOUT)
    check("S1 未配置 maccms 不参与", fetch_calls.maccms == nil)

    tx_deferred[#tx_deferred].cb(
        { { title = "T1", hint = "动漫 | 2023", value = { "t" } } }, nil)

    local final = menu_calls[#menu_calls]
    check("S1 终版分组顺序（跨服务器 bangumiId 去重、maccms 缺席）",
        type(final.item) == "table" and #final.item == 6
        and final.item[1].title == "── dandanplay ──"
        and final.item[2].title == "D1@https://a.example" and final.item[2].hint == "TV动画|主"
        and final.item[3].title == "── 腾讯 ──" and final.item[4].title == "T1"
        and final.item[5].title == "── 360kan ──" and final.item[6].title == "K1")
    check("S1 终版不传 on_close", final.on_close == nil)
    check("S1 latest_menu_anime 已存终版", latest_menu_anime == "json#" .. #menu_calls)
    check("S1 终版后取消注册已清", active_cancel == nil)
end

-- 场景2：腾讯永不回调 → 兜底时限到点渲染「超时」组并杀请求
for _ = 1, 8 do steps[#steps + 1] = function() end end -- 空步（等待 0.8s > 0.3s 时限）
steps[#steps + 1] = function()
    hub.HUB_DEADLINE = 0.3
    menu_calls = {}
    hub.multi_source_search("再搜", nil)
end
for _ = 1, 8 do steps[#steps + 1] = function() end end -- 等时限触发
steps[#steps + 1] = function()
    local final = menu_calls[#menu_calls]
    check("S2 到点终版渲染", type(final.item) == "table" and #final.item == 6)
    check("S2 未完成组标「超时」且杀请求",
        final.item[3].title == "── 腾讯 ──" and final.item[4].title == "超时"
        and tx_deferred[#tx_deferred].cancelled == true)
    check("S2 已完成组正常呈现",
        final.item[1].title == "── dandanplay ──" and final.item[5].title == "── 360kan ──")
    hub.HUB_DEADLINE = 10
end

-- 场景3：中途取消 → 迟到回调丢弃（不再有渲染）
steps[#steps + 1] = function()
    menu_calls = {}
    hub.multi_source_search("三搜", nil)
    check("S3 取消已注册", active_cancel ~= nil)
    active_cancel() -- 模拟菜单关闭触发的复合取消
    local n = #menu_calls
    tx_deferred[#tx_deferred].cb(
        { { title = "迟到T", hint = "x", value = { "t" } } }, nil)
    check("S3 取消后迟到回调被丢弃", #menu_calls == n
        and latest_menu_anime ~= "json#" .. #menu_calls)
end

-- 场景4：@备注 过滤 dandan 服务器（命中取首个；不命中警告后用全部）
steps[#steps + 1] = function()
    options.api_server = "https://a.example|主, https://b.example|备, https://c.example"
    menu_calls = {}
    hub.multi_source_search("四搜", "备")
    check("S4 备注命中只搜该服务器",
        #pr_servers_log[#pr_servers_log] == 1
        and pr_servers_log[#pr_servers_log][1] == "https://b.example")

    msgs = {}
    hub.multi_source_search("五搜", "不存在")
    check("S4 备注不命中警告+全部服务器",
        #pr_servers_log[#pr_servers_log] == 3 and #msgs == 1
        and msgs[1]:find("未找到备注", 1, true) ~= nil)
end

-- 场景5：空查询守卫（不发请求）
steps[#steps + 1] = function()
    local n_tx, n_menu = #tx_deferred, #menu_calls
    hub.multi_source_search("   ", nil)
    check("S5 空查询只出提示行不发请求",
        #menu_calls == n_menu + 1 and menu_calls[#menu_calls].item == "请输入搜索内容"
        and #tx_deferred == n_tx)
end

steps[#steps + 1] = function()
    print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
    mp.commandv("quit", failures == 0 and 0 or 1)
end

local i = 0
local function run_step()
    i = i + 1
    if steps[i] then
        local ok, err = pcall(steps[i])
        if not ok then
            print("FAIL 步骤执行出错: " .. tostring(err))
            failures = failures + 1
        end
        mp.add_timeout(0.1, run_step)
    end
end
mp.add_timeout(0.1, run_step)
