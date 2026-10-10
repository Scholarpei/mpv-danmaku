-- 弹幕源加载状态聚合器：多源并行加载/续载时在同一 OSD 位置动态汇总各源状态
-- （标题+条数+等待/失败标记），供 show_loaded / 续载流程 / 菜单共用。
-- 调用方：main.lua（dandanplay_flow 建会话 / show_loaded 渲染）、apis/*（ensure/mark_*）
--
-- 会话生命周期：file-loaded reset → dandanplay_flow begin（登记 extras 各源 + 等待行）
-- → 各源到货（render_danmaku→show_loaded→format_lines 的自动完成检测）或失败（mark_failed）
-- → 全部终态后汇总多停留数秒。无会话时 format_lines 退化为遍历已加载源（单源一行），
-- 覆盖手动搜索/URL播放/本地xml/重放等无预登记路径，格式与有会话完全一致。
--
-- 竞态说明：标题捕获在各 loader 同步段完成（meta 显式传参），本模块不读 DANMAKU.anime
-- 全局；换集后旧回调的 mark_failed 可能短暂误标新会话同 kind 条目，但成功路径会经
-- ensure 换键 + 自动完成检测收敛到真实状态，故不做逐回调 epoch 校验。
--
-- show_message 与 DANMAKU 为全局（单测时 stub），模块自身无 mp.* 依赖。

local M = {}

local session = nil  -- { entries = { {key, provider, anime, episode, status, count, error} } }
local epoch_counter = 0

local KIND_LABELS = {
    qq = "腾讯视频",
    youku = "优酷",
    mgtv = "芒果TV",
    bilibili = "bilibili",
    bahamut = "巴哈姆特",
    animeko = "animeko",
    maiduidui = "埋堆堆",
    iqiyi = "爱奇艺",
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

-- 建立新会话（换集续载开始时调用，替换旧会话）：
-- entries = { {key=..., provider=..., anime=..., episode=...}, ... }，均登记为等待中
function M.begin(entries)
    epoch_counter = epoch_counter + 1
    session = { epoch = epoch_counter, entries = {} }
    for _, item in ipairs(entries or {}) do
        session.entries[#session.entries + 1] = {
            key = item.key,
            provider = item.provider,
            anime = item.anime,
            episode = item.episode,
            status = "pending",
        }
    end
    M.refresh()
end

-- 登记源（loader 开始加载时调用；无会话时为 no-op，该源走无会话回退显示）。
-- meta: { anime=, episode=, kind= }——kind 用于把 begin 预登记的 "extra:"..kind 占位条目
-- 换键为真实 URL，此后自动完成检测（查 DANMAKU.sources[url].data）即可接管该条目
function M.ensure(key, provider, meta)
    if not session then return end
    meta = meta or {}
    local e = find_entry(key)
    if e == nil and meta.kind then
        e = find_entry("extra:" .. meta.kind)
        if e then e.key = key end
    end
    if e == nil then
        e = { key = key, status = "pending" }
        session.entries[#session.entries + 1] = e
    end
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
    if e == nil or e.status == "done" then return end
    meta = meta or {}
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
    M.refresh()
end

-- 标记失败：reason 为简短原因（会话内由条目的 provider 标注源名）；
-- label 仅供无会话退化单行显示（如「腾讯弹幕续载失败」，与旧独立报错口径一致）
function M.mark_failed(key, reason, label)
    reason = tostring(reason or "加载失败")
    if not session then
        show_message("✗ " .. (label and (label .. "：") or "") .. reason, 3)
        return
    end
    local e = find_entry(key)
    if e == nil or e.status == "done" then return end
    e.status = "failed"
    e.error = reason
    M.refresh()
end

function M.reset()
    session = nil
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
-- / failed「✗ provider：原因」；无标题回退 URL 截断
local function entry_line(e)
    local provider = entry_provider(e)
    local title = source_display_title({anime_title = e.anime, episode_title = e.episode}, e.key, 50)
    if e.status == "failed" then
        return "✗ " .. provider .. "：" .. e.error
    elseif e.status == "pending" then
        return "· " .. provider .. title .. " 等待中…"
    end
    local count = (e.count ~= nil) and (" " .. e.count .. "条") or ""
    return "· " .. provider .. title .. count
end

-- 自动完成检测：pending 条目在 DANMAKU.sources[key] 有数据即转 done（标题/条数就地取）
local function settle()
    if not session then return end
    if type(DANMAKU) ~= "table" or type(DANMAKU.sources) ~= "table" then return end
    for _, e in ipairs(session.entries) do
        if e.status == "pending" then
            local s = DANMAKU.sources[e.key]
            if type(s) == "table" and type(s.data) == "table" and #s.data > 0 then
                e.status = "done"
                e.count = #s.data
                e.anime = e.anime or s.anime_title
                e.episode = e.episode or s.episode_title
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

-- 汇总首行：有等待→加载中；有成功→已加载（带缓存标注）；全败→加载失败
local function header_line(any_pending, any_done)
    if any_pending then
        return "弹幕加载中："
    elseif any_done then
        return "弹幕已加载" .. cache_tag() .. "："
    end
    return "弹幕加载失败" .. cache_tag() .. "："
end

-- 汇总行数组（首行为标题头）：会话模式含等待/失败条目；无会话模式遍历已加载源。
-- 空表 = 无可显示内容（调用方回退到仅统计行）
function M.format_lines()
    settle()
    local lines = {}
    local any_pending, any_done = false, false
    if session then
        for _, e in ipairs(session.entries) do
            if e.status == "pending" then
                any_pending = true
            elseif e.status == "done" then
                any_done = true
            end
            lines[#lines + 1] = entry_line(e)
        end
    else
        if type(DANMAKU) == "table" and type(DANMAKU.sources) == "table" then
            local loaded = {}
            for url, s in pairs(DANMAKU.sources) do
                if type(s) == "table" and type(s.data) == "table" and #s.data > 0 then
                    loaded[#loaded + 1] = {
                        key = url,
                        provider = s.provider,
                        anime = s.anime_title,
                        episode = s.episode_title,
                        count = #s.data,
                    }
                end
            end
            -- pairs 遍历序不稳定，按显示名排序保证确定性
            table.sort(loaded, function(a, b)
                return entry_provider(a) .. a.key < entry_provider(b) .. b.key
            end)
            for _, e in ipairs(loaded) do
                e.status = "done"
                any_done = true
                lines[#lines + 1] = entry_line(e)
            end
        end
    end
    if #lines == 0 then return {} end
    table.insert(lines, 1, header_line(any_pending, any_done))
    return lines
end

-- 刷新 OSD 汇总（同位置动态覆盖）：有等待时持续显示 30s（到货/失败刷新会顶替），
-- 全部终态后停留 6s。无会话时返回 false（调用方保留原有「弹幕加载中...」提示）
function M.refresh()
    if not session then return false end
    local lines = M.format_lines()
    if #lines == 0 then return false end
    show_message(table.concat(lines, "\\N"), M.has_pending() and 30 or 6)
    return true
end

return M
