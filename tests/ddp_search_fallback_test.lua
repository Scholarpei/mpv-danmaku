-- dandanplay 搜索 v2 端点（/api/v2/search/episodes?anime=&v2=true）探测/回退流测试
-- stub parallel_requests + make_danmaku_request_args，直打 hub.start_dandan_search 状态机：
--   探测轮 URL/回退轮 URL/会话级能力记忆（不支持只探一次、支持恒用 v2、网络失败不下结论）/
--   has_more 透传/跨服务器去重/取消传导/进度分母随回退扩大/全错口径
-- stub 契约对齐 utils.parallel_requests：cancel 后不再触发 per_response/final
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local hub = require("modules/search_hub")
require("modules/utils")

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

-- ===== 全局 stub（hub 在调用时读取这些全局） =====

url_encode = function(s) return s end
make_danmaku_request_args = function(method, url) return { url } end
build_dandanplay_menu_item = function(anime, server, note)
    return {
        title = anime.animeTitle .. "@" .. server,
        hint = (anime.typeDescription or "") .. (note and ("|" .. note) or ""),
        bid = anime.bangumiId,
    }
end

-- parallel_requests stub：记录每轮（servers/每服务器 URL/cancel 状态），由测试手动 respond/finish
local rounds = {}
parallel_requests = function(servers, build_args_fn, per_cb, final_cb, opts)
    local round = { servers = servers, opts = opts, per = per_cb, fin = final_cb,
        urls = {}, cancelled = false, final_fired = false }
    for _, s in ipairs(servers) do
        local args = build_args_fn(s)
        round.urls[s] = args and args[1] or "?"
    end
    round.cancel = function()
        if round.cancelled then return end
        round.cancelled = true
    end
    rounds[#rounds + 1] = round
    return round.cancel
end

-- 取消后的迟到响应/收尾按真实契约丢弃（worker 在 aborted 后不触发 per/final）
local function respond(round, server, err, out)
    if round.cancelled then return end
    round.per(server, err, out)
end
local function finish_round(round)
    if round.cancelled or round.final_fired then return end
    round.final_fired = true
    round.fin()
end

local function new_sink()
    local sink = { progress_calls = {}, done_count = 0, done_result = nil }
    sink.progress = function(done, total)
        sink.progress_calls[#sink.progress_calls + 1] = { done = done, total = total }
    end
    sink.done = function(result)
        sink.done_count = sink.done_count + 1
        sink.done_result = result
    end
    return sink
end

-- ===== S1 探测 → 不支持 → 回退轮 → 成功 =====

local S1 = "https://proxy.example"

do
    rounds = {}
    local sink = new_sink()
    hub.start_dandan_search("芙莉莲", { { url = S1 } }, sink)
    check("S1 首轮打 v2 端点", #rounds == 1 and rounds[1].urls[S1]
        :find("/api/v2/search/episodes?anime=芙莉莲&v2=true", 1, true) ~= nil,
        rounds[1] and rounds[1].urls[S1])
    check("S1 首轮并发参数沿用", rounds[1].opts ~= nil
        and rounds[1].opts.concurrency == 5
        and rounds[1].opts.per_request_timeout == hub.PER_SOURCE_TIMEOUT)
    respond(rounds[1], S1, nil, '{"success":false,"errorMessage":"Unsupported API"}')
    finish_round(rounds[1])
    check("S1 不支持即时排旧端点回退轮", #rounds == 2
        and rounds[2].servers[1] == S1
        and rounds[2].urls[S1]:find("/api/v2/search/anime?keyword=芙莉莲", 1, true) ~= nil,
        rounds[2] and rounds[2].urls[S1])
    respond(rounds[2], S1, nil,
        '{"animes":[{"animeTitle":"葬送的芙莉莲","bangumiId":"17617","typeDescription":"TV动画"}]}')
    finish_round(rounds[2])
    check("S1 回退成功单次回调落条目", sink.done_count == 1 and sink.done_result.err == nil
        and #sink.done_result.items == 1
        and sink.done_result.items[1].title == "葬送的芙莉莲@" .. S1
        and sink.done_result.items[1].bid == "17617")
    check("S1 无 hasMore 透传 false", sink.done_result.has_more == false)
    check("S1 进度分母随回退扩大", #sink.progress_calls == 2
        and sink.progress_calls[1].done == 1 and sink.progress_calls[1].total == 1
        and sink.progress_calls[2].done == 2 and sink.progress_calls[2].total == 2)
end

-- ===== S2 能力记忆：不支持只探一次 =====

do
    rounds = {}
    local sink = new_sink()
    hub.start_dandan_search("芙莉莲", { { url = S1 } }, sink)
    check("S2 已记不支持：直接旧端点单轮", #rounds == 1
        and rounds[1].urls[S1]:find("/api/v2/search/anime?", 1, true) ~= nil,
        rounds[1] and rounds[1].urls[S1])
    respond(rounds[1], S1, nil, '{"animes":[]}')
    finish_round(rounds[1])
    check("S2 旧端点空结果为合法空（非错误）", sink.done_count == 1
        and sink.done_result.err == nil and #sink.done_result.items == 0)
end

-- ===== S3 支持端点：单轮直取 + has_more 透传 + 能力记忆 =====

local S3 = "https://danmuapi.example"

do
    rounds = {}
    local sink = new_sink()
    hub.start_dandan_search("海贼王", { { url = S3, note = "自建" } }, sink)
    check("S3 首轮打 v2 端点", #rounds == 1
        and rounds[1].urls[S3]:find("/api/v2/search/episodes?anime=海贼王&v2=true", 1, true) ~= nil)
    respond(rounds[1], S3, nil,
        '{"hasMore":true,"animes":[{"animeTitle":"海贼王","animeId":100889,"typeDescription":"TV动画"}]}')
    finish_round(rounds[1])
    check("S3 支持单轮即成且 has_more 透传", sink.done_count == 1
        and sink.done_result.has_more == true and #sink.done_result.items == 1)
    check("S3 animeId 数字归一为字符串", sink.done_result.items[1].bid == "100889"
        and type(sink.done_result.items[1].bid) == "string")
    check("S3 备注 hint 拼接", sink.done_result.items[1].hint == "TV动画|自建")
    check("S3 截断提示行随 has_more 渲染",
        (function()
            local items = hub.build_grouped_items({ dandanplay = sink.done_result })
            return #items == 3 and items[1].title == "── dandanplay ──"
                and items[3].title == "ⓘ 结果过多已截断，可细化关键词"
        end)())

    rounds = {}
    hub.start_dandan_search("海贼王", { { url = S3 } }, new_sink())
    check("S3 二次搜索仍直打 v2（能力=true 记忆）", #rounds == 1
        and rounds[1].urls[S3]:find("/api/v2/search/episodes?", 1, true) ~= nil)
end

-- ===== S4 混合能力分拣：已知不支持走旧端点、支持走 v2，两轮并行 + 跨服务器去重 =====

do
    rounds = {}
    local sink = new_sink()
    hub.start_dandan_search("M", { { url = S1 }, { url = S3 } }, sink)
    -- 分拣顺序：v2 轮先注册（probe 组），旧端点轮随后（legacy 组）
    check("S4 混合能力两轮并行分拣", #rounds == 2
        and rounds[1].servers[1] == S3
        and rounds[1].urls[S3]:find("/api/v2/search/episodes?", 1, true) ~= nil
        and rounds[2].servers[1] == S1
        and rounds[2].urls[S1]:find("/api/v2/search/anime?", 1, true) ~= nil)
    -- 先响应 S1（bangumiId 字符串 "9"），S3 回数字 animeId 9 + 10：跨端点同 id 去重
    respond(rounds[2], S1, nil, '{"animes":[{"animeTitle":"来自S1","bangumiId":"9"}]}')
    respond(rounds[1], S3, nil,
        '{"animes":[{"animeTitle":"来自S3","animeId":9},{"animeTitle":"来自S3b","animeId":10}]}')
    finish_round(rounds[1])
    check("S4 一轮完另一轮在途不提前回调", sink.done_count == 0)
    finish_round(rounds[2])
    check("S4 跨服务器/跨端点 bangumiId 去重且按配置序拼接",
        sink.done_count == 1 and #sink.done_result.items == 2
        and sink.done_result.items[1].title == "来自S1@" .. S1
        and sink.done_result.items[2].title == "来自S3b@" .. S3)
end

-- ===== S5 网络失败：不回退、不下结论、全错口径 =====

local S5 = "https://dead.example"

do
    rounds = {}
    local sink = new_sink()
    hub.start_dandan_search("Y", { { url = S5 } }, sink)
    check("S5 未知能力先探测 v2", #rounds == 1
        and rounds[1].urls[S5]:find("/api/v2/search/episodes?", 1, true) ~= nil)
    respond(rounds[1], S5, "curl: (28) timed out", nil)
    finish_round(rounds[1])
    check("S5 网络失败不排回退轮且整组报错", #rounds == 1 and sink.done_count == 1
        and sink.done_result.err == "请求失败")
    check("S5 网络失败不写错误条目", sink.done_result.items == nil)

    rounds = {}
    hub.start_dandan_search("Y", { { url = S5 } }, new_sink())
    check("S5 未下结论：下次仍探测 v2", #rounds == 1
        and rounds[1].urls[S5]:find("/api/v2/search/episodes?", 1, true) ~= nil)
end

-- ===== S6 混合：探测网络失败 + 旧端点合法空 → 非全错，空 items（组隐藏） =====

do
    rounds = {}
    local sink = new_sink()
    hub.start_dandan_search("W", { { url = S5 }, { url = S1 } }, sink)
    check("S6 分拣：未知走 v2 / 已知不支持走旧端点", #rounds == 2
        and rounds[1].servers[1] == S5 and rounds[2].servers[1] == S1)
    respond(rounds[1], S5, "connection refused", nil)
    respond(rounds[2], S1, nil, '{"animes":[]}')
    finish_round(rounds[1])
    finish_round(rounds[2])
    check("S6 一错一空不满足全错口径 → 空 items", sink.done_count == 1
        and sink.done_result.err == nil and #sink.done_result.items == 0)
end

-- ===== S7 取消：传导在途轮、迟到响应与回退轮丢弃 =====

do
    local S7 = "https://cancel.example"
    rounds = {}
    local sink = new_sink()
    local cancel = hub.start_dandan_search("Z", { { url = S7 } }, sink)
    check("S7 已发起探测轮", #rounds == 1)
    cancel()
    check("S7 复合取消传导至在途轮", rounds[1].cancelled == true)
    -- 迟到响应与收尾按真实契约丢弃（cancelled 轮不再触发 per/final → 不排回退轮）
    respond(rounds[1], S7, nil, '{"success":false,"errorMessage":"Unsupported API"}')
    finish_round(rounds[1])
    check("S7 取消后不排回退轮不回调", #rounds == 1 and sink.done_count == 0)
end

-- ===== S8 零服务器守卫 =====

do
    rounds = {}
    local sink = new_sink()
    hub.start_dandan_search("Q", {}, sink)
    check("S8 零服务器不发轮直接空结果", #rounds == 0 and sink.done_count == 1
        and sink.done_result.err == nil and #sink.done_result.items == 0)
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
