-- 下一集弹幕预取（追番零等待）
-- 当前集播放进度达到阈值（options.prefetch_next_episode，默认 90%）且播放列表下一项在
-- 同一文件夹时，按文件夹记忆锚点推算「下一集各源该加载什么」，提前把弹幕拉进磁盘缓存
-- （不渲染、不写 sources/history、不发 OSD）。换集时既有加载流程（dandanplay_flow /
-- autoload_bilibili_series / add_danmaku_source_online）缓存命中秒载。
-- 调用方：main.lua（须在 sites/* 之后 require：执行器引用各 fetch/resolve 全局）。
--
-- 取数与正式加载同接口同缓存键，保证换集时键能对上：
--   弹弹play   "ep:{episodeId}"    —— prefetch_dandanplay_episode（apis/dandanplay.lua）
--   直连源     "ext:{url哈希}"      —— resolve_*_episode_url（各 apis）+ fetch_extcomment
--   B站合集   "cid:{cid}"          —— fetch_bilibili_pagelist + 分P匹配 + prefetch_bilibili_danmaku
--   animeko   "ako:{episodeId}"    —— prefetch_animeko_episode（apis/animeko_search.lua）
--   埋堆堆    "mdd:{分集uuid}"     —— prefetch_maiduidui_episode（apis/maiduidui_search.lua）
-- 360kan 的加载路径未接磁盘缓存，暂不预取（plan 直接不排任务）
--
-- 纯函数 plan 与执行/触发分离：plan 无 mp.* 依赖供单元测试（tests/prefetch_plan_test.lua），
-- 集数锚点推算逐式镜像 main.lua 的 dandanplay_flow（modules/history_merge.lua）。

local msg = require("mp.msg")
local utils = require("mp.utils")
local hmerge = require("modules/history_merge")
local bmatch = require("modules/bilibili_match")
local dcache = require("modules/danmaku_cache")

local M = {}

-- 可经 extcomment 缓存预取的直连源 kind → resolver 全局名（require 顺序在 apis 之后，
-- 此处直接引用；缺失（如单测只加载部分 apis）时执行器对该任务按失败容错）
local RESOLVERS = {
    qq = resolve_tencent_episode_url,
    youku = resolve_youku_episode_url,
    mgtv = resolve_mgtv_episode_url,
    bilibili = resolve_bilibili_episode_url,
    bahamut = resolve_bahamut_episode_url,
    iqiyi = resolve_iqiyi_episode_url,
    maccms = resolve_maccms_episode_url,
}

-- ---------------------------------------------------------------------------
-- 纯规划：文件夹记忆记录 + 下一集文件名 → 预取任务列表
-- record：danmaku-history.json 的 history[dir]；next_filename：下一集文件名（去扩展名）
-- parse_fn：utils.get_episode_number（注入供测试）
-- 返回 { {type="ddp", episode_id=, api_server=}, {type="ext", kind=, extra=, episodenum=},
--        {type="bili_series", vid=, rec=, episode=} }（season 由调用方按当前文件注入）
-- ---------------------------------------------------------------------------
function M.plan(record, next_filename, parse_fn)
    local tasks = {}
    if type(record) ~= "table" or type(next_filename) ~= "string" then return tasks end
    if type(parse_fn) ~= "function" then return tasks end

    -- 下一集集数（对全局锚 fname/episodeNumber，与 dandanplay_flow 的推算同式）
    local history_fname = record.fname
    local history_number = record.episodeNumber
    local playing = nil
    if history_fname then
        if next_filename ~= history_fname then
            local _, cur = parse_fn(next_filename, history_fname)
            playing = cur
        else
            playing = history_number
        end
    else
        playing = parse_fn(next_filename)
    end
    if playing == nil or history_number == nil then return tasks end
    local x = playing - history_number

    -- 弹弹play：episodeId 按自己的锚独立推算（快源先写 history 已移动全局锚也不受影响）
    if record.episodeId ~= nil then
        local x_ddp = hmerge.anchor_delta(parse_fn, next_filename, record.episodeId_fname, x)
        tasks[#tasks + 1] = { type = "ddp", episode_id = record.episodeId + x_ddp,
            api_server = record.api_server }
    end

    -- 各直连源 extras：逐锚推算目标集数；按 kind 落到对应任务类型（仅排有缓存触点的 kind）
    for _, ex in ipairs(hmerge.read_extras(record)) do
        if type(ex) == "table" and ex.episodenum ~= nil then
            local kind = ex.kind or "360kan"
            local num = ex.episodenum + hmerge.anchor_delta(parse_fn, next_filename, ex.fname, x)
            if num >= 1 then
                if RESOLVERS[kind] ~= nil then
                    tasks[#tasks + 1] = { type = "ext", kind = kind, extra = ex, episodenum = num }
                elseif kind == "animeko" then
                    tasks[#tasks + 1] = { type = "ako", extra = ex, episodenum = num }
                elseif kind == "maiduidui" then
                    tasks[#tasks + 1] = { type = "mdd", extra = ex, episodenum = num }
                end
            end
        end
    end

    -- B站合集文件夹记忆：按（锚点集数 + 集数差）推算下一集匹配集数；文件名差值解析
    -- 失败时回退锚点 +1（bmatch 自带歧义防护，推不准最多匹配失败跳过，不会错加载）
    local bl = record.bilibili
    if type(bl) == "table" then
        for vid, rec in pairs(bl) do
            if type(rec) == "table" and rec.episode ~= nil then
                local episode = rec.episode + 1
                if history_fname and next_filename ~= history_fname then
                    local a, n = parse_fn(next_filename, history_fname)
                    if a ~= nil and n ~= nil then
                        episode = rec.episode + (n - a)
                    end
                end
                tasks[#tasks + 1] = { type = "bili_series", vid = vid, rec = rec, episode = episode }
            end
        end
    end

    return tasks
end

-- ---------------------------------------------------------------------------
-- 执行：按任务类型写缓存（TTL 命中即跳过网络）
-- ---------------------------------------------------------------------------

-- 直连源：解析目标集 URL → extcomment 取数 → 写 ext: 缓存
local function warm_extcomment(url, done)
    local key = extcomment_cache_key(url)
    if dcache.get(key) then done(true) return end
    fetch_extcomment(url, function(data)
        if not data or type(data.comments) ~= "table" or #data.comments < 1 then
            done(false)
            return
        end
        local n = data.count or #data.comments
        dcache.put(key, utils.format_json({ count = n, comments = data.comments }),
            { type = "json", count = n })
        done(true)
    end)
end

-- B站合集：分P匹配 → cid 弹幕 XML 写 cid: 缓存（不更新记忆锚点——锚点由正式加载更新）
local function warm_bili_series(task, done)
    fetch_bilibili_pagelist(task.vid, function(pages)
        if type(pages) ~= "table" then done(false) return end
        local m = bmatch.match_bilibili_part({
            parts = pages,
            season = task.season,
            episode = task.episode,
            anchor_page = task.rec.page,
            anchor_episode = task.rec.episode,
            anchor_season = task.rec.season,
        })
        local info = m and pages[m.page]
        local cid = info and info["cid"]
        if cid == nil then done(false) return end
        prefetch_bilibili_danmaku(tostring(cid), done)
    end)
end

-- 任务全部完成后回调 done(warmed, total)。单项失败不影响其余（换集时该项照常走网络）
local function execute(tasks, done)
    local remaining, warmed = #tasks, 0
    if remaining == 0 then done(0, 0) return end
    local function one_done(ok)
        if ok then warmed = warmed + 1 end
        remaining = remaining - 1
        if remaining == 0 then done(warmed, #tasks) end
    end
    for _, task in ipairs(tasks) do
        if task.type == "ddp" then
            prefetch_dandanplay_episode(task.episode_id, task.api_server, one_done)
        elseif task.type == "ext" then
            local resolver = RESOLVERS[task.kind]
            if type(resolver) ~= "function" then
                one_done(false)
            else
                resolver(task.extra, task.episodenum, function(url)
                    if not url then one_done(false) return end
                    warm_extcomment(url, one_done)
                end)
            end
        elseif task.type == "ako" then
            -- 站点直连缓存源（animeko）：入口由 apis/animeko_search.lua 定义，单测部分加载时缺省容错
            if type(prefetch_animeko_episode) ~= "function" then
                one_done(false)
            else
                prefetch_animeko_episode(task.extra, task.episodenum, one_done)
            end
        elseif task.type == "mdd" then
            -- 站点直连缓存源（埋堆堆）：入口由 apis/maiduidui_search.lua 定义，单测部分加载时缺省容错
            if type(prefetch_maiduidui_episode) ~= "function" then
                one_done(false)
            else
                prefetch_maiduidui_episode(task.extra, task.episodenum, one_done)
            end
        elseif task.type == "bili_series" then
            warm_bili_series(task, one_done)
        else
            one_done(false)
        end
    end
end

-- ---------------------------------------------------------------------------
-- 触发：percent-pos 达阈值时评估一次（每文件仅一次，防高频重入）
-- ---------------------------------------------------------------------------
local armed = {}  -- path -> true（本文件已评估过预取）

-- 阈值：<=0 关闭；非法回落 90；>100 截到 100
local function threshold()
    local t = tonumber(options.prefetch_next_episode)
    if t == nil then return 90 end
    if t <= 0 then return nil end
    if t > 100 then t = 100 end
    return t
end

function M.maybe_prefetch()
    if not options.auto_load or not dcache.enabled() then return end
    local path = mp.get_property("path")
    if path == nil or is_protocol(path) then return end
    if armed[path] then return end

    local dir = get_parent_directory(path)
    local pos = mp.get_property_number("playlist-playing-pos", -1)
    local count = mp.get_property_number("playlist-count", 1)
    local next_idx = pos + 1
    armed[path] = true  -- 无论后续门槛是否通过，本文件只评估一次
    if dir == nil or next_idx < 1 or next_idx >= count then return end

    local next_path = mp.get_property("playlist/" .. next_idx .. "/filename")
    if type(next_path) ~= "string" or is_protocol(next_path) then return end
    if get_parent_directory(next_path) ~= dir then return end

    local next_fname = next_path:match("([^/\\]+)$")
    if next_fname then next_fname = next_fname:gsub("%.[^./\\]+$", "") end
    if not next_fname or next_fname == "" then return end

    local history_json = read_file(HISTORY_PATH)
    if history_json == nil then return end
    local history = utils.parse_json(history_json) or {}
    local record = history[dir]
    if record == nil then return end

    local tasks = M.plan(record, next_fname, get_episode_number)
    -- B站合集记忆关闭时移除对应任务（plan 纯函数不读 options）
    if options.bilibili_series_memory == "off" then
        local kept = {}
        for _, t in ipairs(tasks) do
            if t.type ~= "bili_series" then kept[#kept + 1] = t end
        end
        tasks = kept
    end
    if #tasks == 0 then return end

    -- season 取当前文件解析值（同文件夹跨季极少见，bmatch 有显式季矛盾排除兜底）
    local _, season = parse_title()
    for _, t in ipairs(tasks) do
        if t.type == "bili_series" then t.season = season and tonumber(season) or nil end
    end

    msg.info(("预取下一集弹幕：%s（%d 项）"):format(next_fname, #tasks))
    execute(tasks, function(warmed, total)
        msg.info(("下一集弹幕预取完成：%d/%d 项已入缓存"):format(warmed, total))
    end)
end

mp.observe_property("percent-pos", "number", function(_, pct)
    local th = threshold()
    if th == nil or pct == nil or pct < th then return end
    M.maybe_prefetch()
end)

return M
