-- 弹幕源加载状态聚合器：多源并行加载/续载时在同一 OSD 位置动态汇总各源状态
-- （标题+条数+等待/失败标记），供 show_loaded / 续载流程 / 菜单共用。
-- 调用方：main.lua（dandanplay_flow 建会话 / show_loaded 渲染）、apis/*（ensure/mark_*）
--
-- 会话生命周期：file-loaded reset → dandanplay_flow begin（登记 extras 各源 + 等待行）
-- → 各源到货（render_danmaku→show_loaded→format_lines 的自动完成检测）或失败（mark_failed）
-- → 全部终态后汇总多停留数秒。
--
-- 会话两型：live（begin 建立，驱动 OSD 动态汇总）与静默（ensure/mark_* 在无会话时自动
-- 创建，live=false，不驱动 OSD 汇总——手动搜索/粘贴 URL 等路径也开始留痕，供「弹幕源
-- 统计」菜单 snapshot 读取；mark_failed/mark_empty 在非 live 会话下保留无会话时代的
-- 单行 OSD 提示口径）。静默会话下 format_lines 走合并分支：会话条目 ∪ 未入会话的
-- 已加载源（key 去重、按显示名排序），失败/等待条目与已加载源同屏。
--
-- 状态四态：pending 等待中 / done 成功（count=条数）/ empty 合法无数据 / failed 失败
-- （error=原因）。empty 与 failed 同为终态，但数据到货（settle 自动完成检测）或
-- mark_done 可翻转为 done（站点报空后兜底/重载给出数据的收敛）；done 不可逆。
--
-- 竞态说明：标题捕获在各 loader 同步段完成（meta 显式传参），本模块不读 DANMAKU.anime
-- 全局；换集后旧回调的 mark_failed 可能短暂误标新会话同 kind 条目，但成功路径会经
-- ensure 换键 + 自动完成检测收敛到真实状态，故不做逐回调 epoch 校验。live 会话下
-- mark_*/note_error 遇未知 key 不新建条目（防 ensure 换键后旧回调 mark 出幽灵行）；
-- 静默会话才允许新建（无 begin 预登记，mark 即首次留痕，provider 取 label）。
--
-- show_message 与 DANMAKU 为全局（单测时 stub），模块自身无 mp.* 依赖。

local M = {}
local duration = require("modules/source_duration")

local session = nil  -- { live = bool, epoch = n, entries = { {key, provider, anime, episode, status, count, error, cache} } }
local epoch_counter = 0
local on_change_fn = nil

local KIND_LABELS = {
    qq = "腾讯视频",
    youku = "优酷",
    mgtv = "芒果TV",
    bilibili = "bilibili",
    bahamut = "巴哈姆特",
    animeko = "animeko",
    maiduidui = "埋堆堆",
    iqiyi = "爱奇艺",
    acf = "AcFun",
    ezd = "ezdmw",
    ggl = "girigirilove",
    ayf = "爱壹帆",
    cyc = "次元城",
    omf = "OmoFun",
    maccms = "maccms",
    ["360kan"] = "360kan",
}

function M.kind_provider_label(kind)
    return KIND_LABELS[kind] or "弹幕源"
end

function M.current_epoch()
    return session and session.epoch or nil
end

local function find_entry(key)
    for _, e in ipairs(session.entries) do
        if e.key == key then return e end
    end
    return nil
end

-- Identity is used only to reject stale asynchronous metadata callbacks.
function M.entry_token(key)
    return session and find_entry(key) or nil
end

function M.note_duration(key, value)
    value = duration.valid(value)
    local e = session and find_entry(key)
    if e and value and e.duration_seconds ~= value then
        e.duration_seconds = value
        if on_change_fn then pcall(on_change_fn) end
    end
end

-- 无会话时自动创建静默会话（不驱动 OSD；手动路径留痕 + 统计菜单读取）
local function ensure_session()
    if session == nil then
        epoch_counter = epoch_counter + 1
        session = { live = false, epoch = epoch_counter, entries = {} }
    end
    return session
end

-- 状态变异通知（menu.lua 注入统计菜单刷新回调；pcall 容错，回调异常不影响台账本身）
local function notify()
    if on_change_fn then pcall(on_change_fn) end
end

-- 建立新会话（换集续载开始时调用，替换旧会话）：
-- entries = { {key=..., provider=..., anime=..., episode=...}, ... }，均登记为等待中
function M.begin(entries)
    epoch_counter = epoch_counter + 1
    session = { live = true, epoch = epoch_counter, entries = {} }
    for _, item in ipairs(entries or {}) do
        session.entries[#session.entries + 1] = {
            key = item.key,
            provider = item.provider,
            anime = item.anime,
            episode = item.episode,
            duration_seconds = duration.valid(item.duration_seconds),
            status = "pending",
        }
    end
    notify()
    M.refresh()
end

-- 登记源（loader 开始加载时调用；无会话时自动创建静默会话留痕）。
-- meta: { anime=, episode=, kind= }——kind 用于把 begin 预登记的 "extra:"..kind 占位条目
-- 换键为真实 URL，此后自动完成检测（查 DANMAKU.sources[url].data）即可接管该条目
function M.ensure(key, provider, meta)
    ensure_session()
    meta = meta or {}
    local e = find_entry(key)
    if e == nil and meta.kind then
        e = find_entry("extra:" .. meta.kind)
        if e then e.key = key end
    end
    if e == nil then
        e = { key = key, status = "pending" }
        session.entries[#session.entries + 1] = e
        notify()
    end
    if duration.valid(meta.duration_seconds) then M.note_duration(key, meta.duration_seconds) end
    if e.status == "pending" then
        if provider ~= nil then e.provider = provider end
        if meta.anime ~= nil then e.anime = meta.anime end
        if meta.episode ~= nil then e.episode = meta.episode end
    end
end

-- 显式标记完成（自动检测覆盖不到的路径，如 B站合集的临时键）
-- meta: { anime=, episode=, count=, url= }（count 缺省时按 url 查 DANMAKU.sources 取条数）
function M.mark_done(key, meta)
    if not session then return end
    local e = find_entry(key)
    if e == nil then return end
    meta = meta or {}
    local src = meta.url and type(DANMAKU)=="table" and DANMAKU.sources[meta.url]
    M.note_duration(key, meta.duration_seconds or (src and src.duration_seconds))
    if e.status == "done" then return end
    if meta.anime ~= nil then e.anime = meta.anime end
    if meta.episode ~= nil then e.episode = meta.episode end
    e.status = "done"
    e.error = nil
    local count = meta.count
    if count == nil and meta.url and type(DANMAKU) == "table" and type(DANMAKU.sources) == "table" then
        local s = DANMAKU.sources[meta.url]
        if type(s) == "table" and type(s.data) == "table" then count = #s.data end
    end
    e.count = count
    notify()
    M.refresh()
end

-- 失败/无数据终态共用落条目逻辑：
-- 非 live（含无会话）保留单行 OSD 口径（live 会话由 refresh 出多行汇总）；
-- live 会话遇未知 key 不新建（防换键后旧回调 mark 出幽灵行），静默会话允许新建
-- （provider 取 label）——mark 即首次留痕
local function terminal_mark(key, status, reason, label)
    if session == nil or session.live ~= true then
        show_message((status == "empty" and "○ " or "✗ ")
            .. (label and (label .. "：") or "") .. reason, 3)
    end
    ensure_session()
    local e = find_entry(key)
    if e == nil then
        if session.live then return end
        session.entries[#session.entries + 1] = { key = key, provider = label, status = status, error = reason }
        e = session.entries[#session.entries]
    elseif e.status == "done" then
        return
    else
        e.status = status
        e.error = reason
    end
    notify()
    M.refresh()
end

-- 标记失败：reason 为简短原因（会话内由条目的 provider 标注源名）；
-- label 仅供非 live 单行显示（如「腾讯弹幕续载失败」，与旧独立报错口径一致）
function M.mark_failed(key, reason, label)
    terminal_mark(key, "failed", tostring(reason or "加载失败"), label)
end

-- 标记合法无数据（终态；数据到货时 settle / mark_done 可转 done）。
-- 各站 loader 自身的空提示与这里的单行 OSD 为同位覆盖，不构成双响干扰
function M.mark_empty(key, reason, label)
    terminal_mark(key, "empty", tostring(reason or "无数据"), label)
end

-- 软错误备注：status 保持 pending、error 记原因（兜底轮进行中的直连失败原因，
-- 全兜底失败时 mark_failed 覆盖为终态）。live 会话遇未知 key 不新建（同 terminal_mark）
function M.note_error(key, reason)
    reason = tostring(reason or "加载失败")
    ensure_session()
    local e = find_entry(key)
    if e == nil then
        if session.live then return end
        session.entries[#session.entries + 1] = { key = key, status = "pending", error = reason }
        e = session.entries[#session.entries]
        notify()
    elseif e.status ~= "done" and e.error ~= reason then
        e.error = reason
        notify()
    end
end

-- per-source 缓存来源标注：e.cache = "cache"/"stale"，同时写全局标量 DANMAKU.cache_hit
-- （保持 show_loaded 的（缓存）/（离线缓存）标注行为）。条目不存在时仅写标量
-- （B站合集 bilibili#vid 临时键等场景，统计详情显示「网络获取」）
function M.note_cache(url, kind)
    if type(DANMAKU) == "table" then
        DANMAKU.cache_hit = kind
    end
    if session == nil then return end
    local e = find_entry(url)
    if e ~= nil and e.cache ~= kind then
        e.cache = kind
        notify()
    end
end

-- 源删除联动：从当前会话移除条目（统计菜单不再显示已删源）；不存在时 no-op
function M.remove(key)
    if session == nil then return end
    for i, e in ipairs(session.entries) do
        if e.key == key then
            table.remove(session.entries, i)
            notify()
            return
        end
    end
end

function M.reset()
    if session ~= nil then
        session = nil
        notify()
    end
end

-- 条目显示名：显式 provider → 运行时源条目 provider → URL 域名推断 → 兜底
local function entry_provider(e)
    if e.provider then return e.provider end
    if type(DANMAKU) == "table" and type(DANMAKU.sources) == "table" then
        local s = DANMAKU.sources[e.key]
        if type(s) == "table" and s.provider then return s.provider end
    end
    if type(provider_label_from_url) == "function" then
        local label = provider_label_from_url(e.key)
        if label then return label end
    end
    return "弹幕源"
end

-- 单行格式：done「· provider《标题》第N话 N条」/ pending「· provider《标题》 等待中…」
-- / failed「✗ provider：原因」/ empty「○ provider：原因」；无标题回退 URL 截断
local function entry_line(e)
    local provider = entry_provider(e)
    local title = source_display_title({anime_title = e.anime, episode_title = e.episode}, e.key, 50)
    if e.status == "failed" then
        return "✗ " .. provider .. "：" .. e.error
    elseif e.status == "empty" then
        return "○ " .. provider .. "：" .. e.error
    elseif e.status == "pending" then
        return "· " .. provider .. title .. " 等待中…"
    end
    local count = (e.count ~= nil) and (" " .. e.count .. "条") or ""
    local line = "· " .. provider .. title .. count
    -- 时间轴对齐标注：管线写入源记录的瞬态校正量（非 0 时显示整源平移秒数）
    if type(DANMAKU) == "table" and type(DANMAKU.sources) == "table" then
        local s = DANMAKU.sources[e.key]
        if type(s) == "table" and type(s.align_shift) == "number" and s.align_shift ~= 0 then
            line = line .. string.format(" 源间%+.2fs", s.align_shift)
        end
    end
    if type(DANMAKU)=='table' and DANMAKU.sources then
        local s=DANMAKU.sources[e.key]
        if s and s.timeline_status then line=line..' '..s.timeline_status end
    end
    return line
end

-- 自动完成检测：pending/empty 条目在 DANMAKU.sources[key] 有数据即转 done
-- （empty 可翻转：站点报空后兜底/重载实际给出数据时统计如实反映现状）
local function settle()
    if not session then return end
    if type(DANMAKU) ~= "table" or type(DANMAKU.sources) ~= "table" then return end
    for _, e in ipairs(session.entries) do
        if e.status == "pending" or e.status == "empty" then
            local s = DANMAKU.sources[e.key]
            if type(s) == "table" and type(s.data) == "table" and #s.data > 0 then
                e.status = "done"
                e.count = #s.data
                e.anime = e.anime or s.anime_title
                e.episode = e.episode or s.episode_title
                e.duration_seconds = duration.valid(s.duration_seconds) or e.duration_seconds
            end
        end
    end
end

function M.has_pending()
    if not session then return false end
    for _, e in ipairs(session.entries) do
        if e.status == "pending" then return true end
    end
    return false
end

local function cache_tag()
    if type(DANMAKU) == "table" then
        if DANMAKU.cache_hit == "cache" then return "（缓存）" end
        if DANMAKU.cache_hit == "stale" then return "（离线缓存）" end
    end
    return ""
end

-- 汇总首行：有等待→加载中；有成功→已加载（带缓存标注）；仅无数据→无数据；全败→加载失败
local function header_line(any_pending, any_done, any_empty)
    if any_pending then
        return "弹幕加载中："
    elseif any_done then
        return "弹幕已加载" .. cache_tag() .. "："
    elseif any_empty then
        return "弹幕无数据" .. cache_tag() .. "："
    end
    return "弹幕加载失败" .. cache_tag() .. "："
end

-- 汇总行数组（首行为标题头）：
-- live 会话：会话条目逐行（含等待/失败/无数据）；
-- 静默/无会话：合并分支——会话条目 ∪ 未入会话的已加载源（key 去重、按显示名排序），
-- 手动路径下失败/等待条目与已加载源同屏（旧无会话分支只列已加载源）。
-- 空表 = 无可显示内容（调用方回退到仅统计行）
function M.format_lines()
    settle()
    local lines = {}
    local any_pending, any_done, any_empty = false, false, false
    local function account(e)
        if e.status == "pending" then
            any_pending = true
        elseif e.status == "done" then
            any_done = true
        elseif e.status == "empty" then
            any_empty = true
        end
    end
    if session and session.live then
        for _, e in ipairs(session.entries) do
            account(e)
            lines[#lines + 1] = entry_line(e)
        end
    else
        local rows = {}
        if session then
            for _, e in ipairs(session.entries) do
                rows[#rows + 1] = e
            end
        end
        if type(DANMAKU) == "table" and type(DANMAKU.sources) == "table" then
            local in_session = {}
            for _, e in ipairs(rows) do in_session[e.key] = true end
            for url, s in pairs(DANMAKU.sources) do
                if not in_session[url] and type(s) == "table" and type(s.data) == "table" and #s.data > 0 then
                    rows[#rows + 1] = {
                        key = url,
                        provider = s.provider,
                        anime = s.anime_title,
                        episode = s.episode_title,
                        count = #s.data,
                        status = "done",
                    }
                end
            end
        end
        -- pairs 遍历序不稳定，按显示名排序保证确定性
        table.sort(rows, function(a, b)
            return entry_provider(a) .. a.key < entry_provider(b) .. b.key
        end)
        for _, e in ipairs(rows) do
            account(e)
            lines[#lines + 1] = entry_line(e)
        end
    end
    if #lines == 0 then return {} end
    table.insert(lines, 1, header_line(any_pending, any_done, any_empty))
    return lines
end

-- 刷新 OSD 汇总（同位置动态覆盖）：有等待时持续显示 30s（到货/失败刷新会顶替），
-- 全部终态后停留 6s。live 会话以外返回 false（调用方保留原有「弹幕加载中...」提示）
function M.refresh()
    if not session or session.live ~= true then return false end
    local lines = M.format_lines()
    if #lines == 0 then return false end
    show_message(table.concat(lines, "\\N"), M.has_pending() and 30 or 6)
    return true
end

-- 条目快照（统计菜单/测试唯一读出口）：先 settle 再浅拷贝隔离内部状态
-- （条目字段全为标量，浅拷贝即隔离），provider 就地解析为最终显示名
function M.snapshot()
    settle()
    if session == nil then return { live = false, entries = {} } end
    local entries = {}
    for _, e in ipairs(session.entries) do
        entries[#entries + 1] = {
            key = e.key,
            provider = entry_provider(e),
            anime = e.anime,
            episode = e.episode,
            status = e.status,
            count = e.count,
            error = e.error,
            cache = e.cache,
            duration_seconds = e.duration_seconds,
        }
    end
    return { live = session.live, entries = entries }
end

-- 状态变异回调（menu.lua 注入统计菜单刷新；模块自身无 mp.* 依赖——回调为外部
-- 注入的普通函数，异常经 pcall 吞掉不影响台账）
function M.set_on_change(fn)
    on_change_fn = fn
end

return M
