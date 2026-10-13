-- fallback_server 多服务器顺序尝试单元测试（apis/dandanplay.lua 的 do_fallback/dispatch_result）：
-- 逗号分隔列表依次尝试直到任一成功、首个成功即止、全部失败才上报一次失败状态、
-- 空配置零请求并上报「直连失败且未配置备用服务器」（弹幕源统计留痕——旧行为为静默丢弃）、
-- 单服务器行为不变、
-- ezdmw 分支 no_data 判定跳过兜底轮（确定性无弹幕不轮询 dmku）改记 empty 终态、
-- cb(false) 仍走兜底；直连失败原因软记录（note_error）与终态拼接；
-- 兜底链网络错误续试下一台（修复旧实现 error 分支不回调导致的静默中断）
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
    _G.__fb_last_failed = { query = query, err = err, provider = provider }
end
ss.mark_empty = function(query, reason, label)
    _G.__fb_mark_empty = (_G.__fb_mark_empty or 0) + 1
    _G.__fb_last_empty = { query = query, reason = reason, label = label }
end
ss.note_error = function(key, reason)
    _G.__fb_note_error = (_G.__fb_note_error or 0) + 1
    _G.__fb_last_note = { key = key, reason = reason }
end

require("modules/options")
require("modules/utils")
require("modules/parse")
require("apis/dandanplay")

-- ---- require 后二次打桩（dandanplay.lua 已定义真身全局，调用点按全局查找）----
local attempted = {}
local resp_by_server = {}
local err_by_server = {}

make_danmaku_request_args = function(method, url)
    return { "curl", "-s", url }
end
fetch_danmaku_data = function(args, callback, on_error)
    local url = args[#args]
    local server = url:match("^(https?://[^/]+)")
    attempted[#attempted + 1] = server
    mp.add_timeout(0.01, function()
        if err_by_server[server] then
            -- 网络层失败：有 on_error 钩子则走钩子（旧实现不传钩子时此处即链尾静默中断）
            if on_error then on_error(err_by_server[server]) end
            return
        end
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
    check("无直连原因时不拼接", _G.__fb_last_failed.err == "无数据或返回格式不正确",
        _G.__fb_last_failed.err)
    check("失败不落源", DANMAKU.sources[QUERY] == nil)
end

-- ---------- 空配置：零请求 + 上报直连失败且未配置备用服务器 ----------
-- （旧行为为整条失败链静默丢弃；弹幕源统计功能改为如实上报留痕）
steps[5] = function()
    options.fallback_server = ""
    attempted = {}
    _G.__fb_mark_failed = 0
    get_danmaku_fallback(QUERY)
end

steps[6] = function()
    check("空配置零请求", #attempted == 0)
    check("空配置上报一次", _G.__fb_mark_failed == 1)
    check("空配置无直连分支文案", _G.__fb_last_failed.err == "直连失败且未配置备用服务器",
        _G.__fb_last_failed.err)
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

-- ---------- ezdmw：E站确定性无弹幕（no_data 判定）跳过兜底轮改记 empty；cb(false) 仍走兜底 ----------
-- dmku 兜底服务器只按主流站点 URL 索引，永远不会有 ezdmw.org 数据：E站侧已确定无弹幕
-- 时再轮询兜底只产生噪音与误导性「获取数据失败」
local EZD_Q = "https://www.ezdmw.org/Index/video/32869.html"

steps[9] = function()
    options.fallback_server = "https://s1.example,https://s2.example"
    resp_by_server = {}
    attempted = {}
    _G.__fb_mark_failed = 0
    _G.__fb_mark_empty = 0
    load_danmaku_for_ezdmw = function(q, cb)
        mp.add_timeout(0.01, function() cb(false, true, "该集无弹幕资源") end)
    end
    get_danmaku_fallback(EZD_Q)
end

steps[10] = function()
    check("ezd no_data 零兜底请求", #attempted == 0)
    check("ezd no_data 不上报失败", _G.__fb_mark_failed == 0)
    check("ezd no_data 记 empty 带原因", _G.__fb_mark_empty == 1
        and _G.__fb_last_empty.reason == "该集无弹幕资源"
        and _G.__fb_last_empty.query == EZD_Q,
        _G.__fb_last_empty and _G.__fb_last_empty.reason)
    -- 对照：无 no_data 判定（真网络失败口径）仍须走兜底
    load_danmaku_for_ezdmw = function(q, cb)
        mp.add_timeout(0.01, function() cb(false) end)
    end
    DANMAKU.sources[EZD_Q] = nil
    get_danmaku_fallback(EZD_Q)
end

steps[11] = function()
    check("ezd 网络失败仍逐一走兜底", #attempted == 2)
    check("ezd 网络失败上报一次", _G.__fb_mark_failed == 1)
    check("ezd 无原因不写软备注", _G.__fb_last_failed.err == "无数据或返回格式不正确",
        _G.__fb_last_failed.err)
    check("ezd 兜底失败不落源", DANMAKU.sources[EZD_Q] == nil)
end

-- ---------- 腾讯直连失败带原因 + 兜底成功：软记录原因、零终态失败 ----------
local QQ_Q = "https://v.qq.com/x/cover/a/b.html"

steps[12] = function()
    options.fallback_server = "https://s1.example"
    resp_by_server = { ["https://s1.example"] = { comments = { {}, {} }, count = 2 } }
    err_by_server = {}
    attempted = {}
    _G.__fb_mark_failed = 0
    _G.__fb_note_error = 0
    load_danmaku_for_tencent = function(q, cb)
        mp.add_timeout(0.01, function() cb(false, nil, "弹幕分段索引为空") end)
    end
    DANMAKU.sources[QQ_Q] = nil
    get_danmaku_fallback(QQ_Q)
end

steps[13] = function()
    check("直连失败软记录原因", _G.__fb_note_error == 1
        and _G.__fb_last_note.key == QQ_Q
        and _G.__fb_last_note.reason == "弹幕分段索引为空",
        _G.__fb_last_note and _G.__fb_last_note.reason)
    check("兜底成功零失败上报", _G.__fb_mark_failed == 0)
    check("兜底成功落源", DANMAKU.sources[QQ_Q] ~= nil)
end

-- ---------- 腾讯直连失败带原因 + 全兜底失败：终态 reason 拼接直连原因 ----------
steps[14] = function()
    resp_by_server = { ["https://s1.example"] = nil }
    attempted = {}
    _G.__fb_mark_failed = 0
    load_danmaku_for_tencent = function(q, cb)
        mp.add_timeout(0.01, function() cb(false, nil, "没有找到弹幕分段") end)
    end
    DANMAKU.sources[QQ_Q] = nil
    get_danmaku_fallback(QQ_Q)
end

steps[15] = function()
    check("全兜底失败上报一次", _G.__fb_mark_failed == 1)
    check("终态reason拼接直连原因", _G.__fb_last_failed.err ~= nil
        and _G.__fb_last_failed.err:find("没有找到弹幕分段") ~= nil
        and _G.__fb_last_failed.err:find("直连失败") ~= nil, _G.__fb_last_failed.err)
end

-- ---------- 腾讯直连失败带原因 + 空配置：直连失败（原因）且未配置备用服务器 ----------
steps[16] = function()
    options.fallback_server = ""
    attempted = {}
    _G.__fb_mark_failed = 0
    get_danmaku_fallback(QQ_Q)
end

steps[17] = function()
    check("空配置零请求", #attempted == 0)
    check("空配置上报带原因", _G.__fb_mark_failed == 1
        and _G.__fb_last_failed.err == "直连失败（没有找到弹幕分段）且未配置备用服务器",
        _G.__fb_last_failed.err)
end

-- ---------- 兜底链网络错误续试下一台（修复旧静默中断） ----------
steps[18] = function()
    options.fallback_server = "https://n1.example,https://n2.example"
    err_by_server = { ["https://n1.example"] = "curl exit 7" }
    resp_by_server = { ["https://n2.example"] = { comments = { {}, {} }, count = 2 } }
    attempted = {}
    DANMAKU.sources[QUERY] = nil
    get_danmaku_fallback(QUERY)
end

steps[19] = function()
    check("网络错误续试次序", #attempted == 2 and attempted[1] == "https://n1.example"
        and attempted[2] == "https://n2.example", table.concat(attempted, ","))
    check("续试成功落源", DANMAKU.sources[QUERY] ~= nil)
    err_by_server = {}
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
