-- 重建调度器：把「短时间内的多次全量管线重建请求」合并为一次执行。
-- 服务两类调用方：
--   ① 弹幕源到货（load_danmaku 第三参 arrival）：首源立即重建（用户无感延迟），
--      防抖窗口内的后续到货合并为一次重建（此前每源到货各跑一遍完整管线，
--      含 pakku 合并 100-250ms，双源场景加载期突发两次卡顿）；
--   ② 延迟调整（set_danmaku_delay 末尾）：trailing-only 防抖，替代原局部 timer。
-- 两类共用同一个 timer 槽：同时发生时后到的请求 kill 并覆盖先到的 pending
-- （两者都是全量重建+渲染，覆盖仅损失 OSD 提示差异，换来绝不双跑）。
-- 无 mp.* 依赖（add_timeout/time 由 setup 注入）以便单元测试。

local M = {}

local add_timeout_fn = nil
local time_fn = nil
local timer = nil       -- 当前挂起的防抖 timer
local pending = nil     -- timer 到期要执行的 run（调用方闭包内自持合并上下文）
local last_run = 0      -- 上次实际执行时刻（run_now / 防抖到期时更新）

function M.setup(opts)
    add_timeout_fn = opts.add_timeout
    time_fn = opts.time
end

-- trailing 防抖请求：opts = { window = 秒, run = fn }
-- 已有 pending 时 kill 旧 timer 重启窗口（滑动窗口：每个新请求重置计时，
-- 多源陆续到货时最终只在最后一个到货后 window 秒执行一次）
function M.request(opts)
    if not add_timeout_fn then
        -- 未 setup（异常环境）直接执行，宁重不缺
        opts.run()
        return
    end
    if timer then timer:kill() end
    pending = opts.run
    timer = add_timeout_fn(opts.window, function()
        timer = nil
        local run = pending
        pending = nil
        if run then
            last_run = time_fn()
            run()
        end
    end)
end

-- 立即执行并记录时刻（首源到货路径用）
function M.run_now(fn)
    last_run = time_fn()
    fn()
end

-- 距上次实际执行是否已超过 window（首源「立即显示」判据；需配合 not has_pending）
function M.idle(window)
    return (time_fn() - last_run) >= window
end

-- 是否有挂起的防抖请求（有 pending 时新到货必须合并而非再走 leading）
function M.has_pending()
    return timer ~= nil
end

-- 清空挂起请求（换集 on_unload 调用，防旧 timer 重建已清空的 DANMAKU）
function M.cancel()
    if timer then
        timer:kill()
        timer = nil
    end
    pending = nil
end

return M
