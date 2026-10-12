-- rebuild_sched 单元测试（自断言，输出 PASS/FAIL 行）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local sched = require("modules/rebuild_sched")

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

-- 可控时间 + 定时器桩：捕获 (delay, fn) 不自动执行，手动 fire
do
    local now = 100.0
    local armed = nil      -- { delay, fn, killed }
    sched.setup({
        time = function() return now end,
        add_timeout = function(delay, fn)
            armed = { delay = delay, fn = fn, killed = false }
            armed.kill = function() armed.killed = true end
            return armed
        end,
    })

    local function fire_armed()
        local t = armed
        armed = nil
        if t and not t.killed then t.fn() end
    end

    -- A. trailing 请求不立即执行，到期执行一次
    local ran = 0
    sched.request({ window = 0.2, run = function() ran = ran + 1 end })
    check("A1 request 后不立即执行", ran == 0)
    check("A2 有 pending", sched.has_pending())
    check("A3 timer 延时为 window", armed and armed.delay == 0.2)
    fire_armed()
    check("A4 到期执行恰好一次", ran == 1)
    check("A5 执行后无 pending", not sched.has_pending())

    -- B. 滑动窗口：窗口内第二个请求 kill 旧 timer 重启，只执行最后一次的 run
    local which = nil
    sched.request({ window = 0.2, run = function() which = "first" end })
    local first_timer = armed
    sched.request({ window = 0.2, run = function() which = "second" end })
    check("B1 第二请求 kill 旧 timer", first_timer.killed)
    fire_armed()
    check("B2 只执行最后一次的 run", which == "second")

    -- C. run_now 立即执行且更新 last_run → idle 立即变 false
    local ran_now = 0
    now = now + 5 -- 离 A/B 组的 last_run 足够远，恢复「久未执行」态
    check("C1 idle 初始为真（久未执行）", sched.idle(0.2))
    sched.run_now(function() ran_now = ran_now + 1 end)
    check("C2 run_now 立即执行", ran_now == 1)
    check("C3 run_now 后 idle 为假", not sched.idle(0.2))
    now = now + 0.3
    check("C4 时间推进超过窗口后 idle 恢复为真", sched.idle(0.2))

    -- D. pending 期间 idle 仍可能为真 → 调用方须配合 has_pending 判 leading（文档行为）
    now = 1000.0 -- 远离 last_run，idle 必为真
    sched.request({ window = 0.2, run = function() end })
    check("D1 pending 时 has_pending 为真", sched.has_pending())
    check("D2 pending 不影响 idle 判定（调用方须双条件）", sched.idle(0.2))
    fire_armed()

    -- E. cancel：kill timer，到期闭包不执行
    local cancelled_ran = 0
    sched.request({ window = 0.2, run = function() cancelled_ran = cancelled_ran + 1 end })
    local pending_timer = armed
    sched.cancel()
    check("E1 cancel kill timer", pending_timer.killed)
    check("E2 cancel 后无 pending", not sched.has_pending())
    fire_armed()
    check("E3 cancel 后 run 不执行", cancelled_ran == 0)

    -- F. 防抖到期执行后再次 request 正常（复用调度器）
    local again = 0
    sched.request({ window = 0.1, run = function() again = again + 1 end })
    fire_armed()
    check("F1 到期执行后再 request 正常", again == 1)

    -- G. 连续 request 多次最终只跑一次（3 源场景）
    local merged = 0
    for i = 1, 3 do
        sched.request({ window = 0.2, run = function() merged = merged + 1 end })
    end
    fire_armed()
    check("G1 三连 request 合并为一次执行", merged == 1)
end

-- H. 未 setup 时 request 直接执行（异常兜底：宁重不缺）
do
    local fresh = dofile((root .. "/modules/rebuild_sched.lua"):gsub("\\", "/"))
    local ran = 0
    fresh.request({ window = 0.2, run = function() ran = ran + 1 end })
    check("H1 未 setup 时 request 直接执行", ran == 1)
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
-- os.exit 直杀：mpv 正常 quit 的关机路径在 Windows 控制台代理下偶发挂起（测试环境已知问题）
os.exit(failures > 0 and 1 or 0)
