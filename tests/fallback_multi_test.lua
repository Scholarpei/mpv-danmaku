-- fallback_server 多服务器顺序尝试单元测试（apis/dandanplay.lua 的 do_fallback）：
-- 逗号分隔列表依次尝试直到任一成功、首个成功即止、全部失败才上报一次失败状态、
-- 空配置静默返回（保持旧行为）、单服务器行为不变
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

-- ---- 打桩（须在 require 前；dandanplay.lua 加载期引用这些全局）----
show_message = function() end
load_danmaku = function() end
DANMAKU = { sources = {} }

-- source_status 被 dandanplay.lua 以 local 捕获，须包装真实模块（package.loaded 同表）
local ss = require("modules/source_status")
ss.mark_failed = function(query, err, provider)
    _G.__fb_mark_failed = (_G.__fb_mark_failed or 0) + 1
end

require("modules/options")
require("modules/utils")
require("modules/parse")
require("apis/dandanplay")

-- ---- require 后二次打桩（dandanplay.lua 已定义真身全局，调用点按全局查找）----
local attempted = {}
local resp_by_server = {}

make_danmaku_request_args = function(method, url)
    return { "curl", "-s", url }
end
fetch_danmaku_data = function(args, callback)
    local url = args[#args]
    local server = url:match("^(https?://[^/]+)")
    attempted[#attempted + 1] = server
    mp.add_timeout(0.01, function()
        callback(resp_by_server[server])
    end)
end
save_danmaku_data = function(comments, query, src)
    DANMAKU.sources[query] = { from = src, data = comments }
end

local QUERY = "https://example.com/video/12345"
local steps = {}

-- ---------- 三服务器：首个失败续试，第二个成功即止 ----------
steps[1] = function()
    options.fallback_server = "https://s1.example, https://s2.example,https://s3.example"
    resp_by_server = {
        ["https://s1.example"] = nil,                               -- 无响应
        ["https://s2.example"] = { comments = { {}, {}, {} }, count = 3 }, -- 有效
        ["https://s3.example"] = { comments = { {} }, count = 1 },  -- 不应触达
    }
    attempted = {}
    _G.__fb_mark_failed = 0
    get_danmaku_fallback(QUERY)
end

steps[2] = function()
    check("失败续试次序", #attempted == 2 and attempted[1] == "https://s1.example"
        and attempted[2] == "https://s2.example", table.concat(attempted, ","))
    check("成功即止不触达第三台", #attempted == 2)
    check("成功数据落源", DANMAKU.sources[QUERY] ~= nil
        and DANMAKU.sources[QUERY].provider == "兜底服务器")
    check("成功不上报失败", _G.__fb_mark_failed == 0)
end

-- ---------- 全部失败：逐一尝试后上报一次 ----------
steps[3] = function()
    resp_by_server = {
        ["https://s1.example"] = nil,
        ["https://s2.example"] = { comments = { {} }, count = 1 }, -- count<=1 视为无效
        ["https://s3.example"] = nil,
    }
    attempted = {}
    _G.__fb_mark_failed = 0
    DANMAKU.sources[QUERY] = nil
    get_danmaku_fallback(QUERY)
end

steps[4] = function()
    check("全部失败逐一尝试", #attempted == 3)
    check("全部失败上报一次", _G.__fb_mark_failed == 1)
    check("失败不落源", DANMAKU.sources[QUERY] == nil)
end

-- ---------- 空配置：静默返回（旧行为保持） ----------
steps[5] = function()
    options.fallback_server = ""
    attempted = {}
    _G.__fb_mark_failed = 0
    get_danmaku_fallback(QUERY)
end

steps[6] = function()
    check("空配置零请求", #attempted == 0)
    check("空配置不上报失败", _G.__fb_mark_failed == 0)
end

-- ---------- 单服务器 + xml 分支行为不变 ----------
steps[7] = function()
    options.fallback_server = "https://xml.example"
    resp_by_server = { ["https://xml.example"] = { xml = { { text = "x", time = 1 } } } }
    attempted = {}
    get_danmaku_fallback(QUERY)
end

steps[8] = function()
    local src = DANMAKU.sources[QUERY]
    check("xml 分支落源", src ~= nil and src.provider == "兜底服务器" and src.data ~= nil)
    check("xml 分支单请求", #attempted == 1)
end

local function finish()
    print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
    -- os.exit 直杀：mpv 正常 quit 的关机路径在 Windows 控制台代理下偶发挂起（测试环境已知问题）
    os.exit(failures > 0 and 1 or 0)
end

local function run(i)
    local s = steps[i]
    if not s then
        finish()
        return
    end
    mp.add_timeout(0.15, function()
        s()
        run(i + 1)
    end)
end

run(1)
