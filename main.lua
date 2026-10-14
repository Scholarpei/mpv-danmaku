VERSION = "2.2.0"

mp.commandv('script-message', 'uosc_danmaku-version', VERSION)

local msg = require('mp.msg')
local utils = require("mp.utils")

AES = require("modules/aes")
Base64 = require("modules/base64")
MD5 = require("modules/md5")
Sha256 = require("modules/hash")
hmerge = require("modules/history_merge")
source_status = require("modules/source_status")

require("modules/options")
require("modules/utils")
require("modules/parse")
require("modules/guess")
require('modules/render')
require('modules/menu')
require('modules/density_timeline')
require("modules/update")

require("apis/dandanplay")
require('apis/extra')
require("apis/tencent_search")
require("apis/maccms")
require("apis/youku_search")
require("apis/mgtv_search")
require("apis/bilibili_search")
require("apis/bahamut_search")
require("apis/animeko_search")
require("apis/maiduidui_search")
require("apis/iqiyi_search")
require("apis/acfun_search")
require("apis/ezdmw_search")
require("apis/ggl_search")
require("apis/aiyifan_search")
require("apis/cyc_search")

-- 多源聚合搜索（须在 apis 之后：运行时调用各 fetch/build 全局）
search_hub = require("modules/search_hub")

require("sites/bilibili")
require("sites/bahamut")
require("sites/iqiyi")
require("sites/mgtv")
require("sites/tencentvideo")
require("sites/youku")
require("sites/animeko")
require("sites/maiduidui")
require("sites/acfun")
require("sites/ezdmw")
require("sites/ggl")
require("sites/aiyifan")
require("sites/cyc")

-- 下一集弹幕预取（须在 apis 与 sites 之后：执行器引用 fetch_extcomment /
-- resolve_*_episode_url / fetch_bilibili_pagelist 等运行时全局）
prefetch = require("modules/prefetch")

DANMAKU_PATH = os.getenv("TEMP") or "/tmp/"
HISTORY_PATH = mp.command_native({"expand-path", options.history_path})
PID = utils.getpid()
DANMAKU = {sources = {}, count = 1}
ENABLED, FALLBACK_TRIGGER, COMMENTS, DELAY = false, false, nil, 0
DELAY_PROPERTY = string.format("user-data/%s/danmaku-delay", mp.get_script_name())
mp.set_property_native(DELAY_PROPERTY, 0)
HAS_DANMAKU = string.format("user-data/%s/has-danmaku", mp.get_script_name())
mp.set_property_bool(HAS_DANMAKU, false)
DANMAKU_SWITCH_ON = string.format("user-data/%s/danmaku-switch-on", mp.get_script_name())
mp.set_property_bool(DANMAKU_SWITCH_ON, false)
DANMAKU_COUNT = string.format("user-data/%s/danmaku-count", mp.get_script_name())
mp.set_property_native(DANMAKU_COUNT, 0)
KEY = table_to_zero_indexed({
    0x00,0x01,0x02,0x03,0x04,
    0x05,0x06,0x07,0x08,0x09,
    0x0a,0x0b,0x0c,0x0d,0x0e,
    0x0f,0x10,0x11,0x12,0x13,
    0x14,0x15,0x16,0x17,0x18,
    0x19,0x1a,0x1b,0x1c,0x1d,
    0x1e,0x1f
})

PLATFORM = (function()
    local platform = mp.get_property_native("platform")
    if platform then
        if itable_index_of({ "windows", "darwin" }, platform) then
            return platform
        end
    else
        if os.getenv("windir") ~= nil then
            return "windows"
        end
        local homedir = os.getenv("HOME")
        if homedir ~= nil and string.sub(homedir, 1, 6) == "/Users" then
            return "darwin"
        end
    end
    return "linux"
end)()

-- 弹幕磁盘缓存初始化（需在 PLATFORM 检测之后；目录放 ~~/ 下避开 update.lua 自更新清脚本目录；
-- 建目录失败时模块内部静默禁用，功能退化为不缓存）
danmaku_cache = require("modules/danmaku_cache")
danmaku_cache.setup({
    enabled = options.danmaku_cache_enabled,
    dir = mp.command_native({ "expand-path", options.danmaku_cache_path }),
    ttl_seconds = (tonumber(options.danmaku_cache_ttl_days) or 0) * 86400,
    max_bytes = (tonumber(options.danmaku_cache_max_mb) or 0) * 1024 * 1024,
    platform = PLATFORM,
    run_sync = function(cmd) return mp.command_native(cmd) end,
    defer = function(delay, fn) mp.add_timeout(delay, fn) end,
    log = function(level, text) msg[level](text) end,
})

-- 重建调度器（到货防抖 + 延迟防抖共用；add_timeout/time 注入供单测）
sched = require("modules/rebuild_sched")
sched.setup({
    add_timeout = mp.add_timeout,
    time = mp.get_time,
})

-- show_danmaku 会话级标量缓存：toggle/启动按钮等高频读取不再每次读+解析整个 history JSON
-- （该文件同时含番剧历史等大对象）。只缓存此标量不缓存整表——文件被 write_history 等
-- 十余处独立 read-modify-write，整表缓存会引入丢写竞态；写侧维持写透（用户级低频操作）
local cached_show_danmaku = nil

function get_danmaku_visibility()
    if cached_show_danmaku ~= nil then return cached_show_danmaku end
    local history_json = read_file(HISTORY_PATH)
    local history
    if history_json ~= nil then
        history = utils.parse_json(history_json) or {}
        local flag = history["show_danmaku"]
        if flag == nil then
            history["show_danmaku"] = false
            write_json_file(HISTORY_PATH, history)
        else
            cached_show_danmaku = flag
            return flag
        end
    else
        history = {}
        history["show_danmaku"] = false
        write_json_file(HISTORY_PATH, history)
    end
    return false
end

function set_danmaku_visibility(flag)
    cached_show_danmaku = flag
    local history = {}
    local history_json = read_file(HISTORY_PATH)
    if history_json ~= nil then
        history = utils.parse_json(history_json) or {}
    end
    history["show_danmaku"] = flag
    write_json_file(HISTORY_PATH, history)
end

function set_danmaku_button()
    if get_danmaku_visibility() then
        toggle_danmaku_switch("on")
    end
end

function show_loaded(init)
    if not COMMENTS then
        show_message("comments无数据", 3)
        msg.error("comments无数据")
        return
    end
    -- pakku popup 风格合并统计（实际发生合并时才显示；「共计」为密度限制后的最终条数，故两者可不同）
    local merge_line = ""
    if MERGE_STATS and MERGE_STATS.before > MERGE_STATS.after then
        merge_line = ("已合并 %d 条相似弹幕（%d→%d）\\N"):format(
            MERGE_STATS.before - MERGE_STATS.after, MERGE_STATS.before, MERGE_STATS.after)
    end
    -- pakku 式智能密度统计（实际发生干预时才显示；「共计」为布局后最终条数，可进一步少于 after）
    local density_line = ""
    if DENSITY_STATS and (DENSITY_STATS.shrunk > 0 or DENSITY_STATS.dropped > 0) then
        density_line = ("智能密度：缩小 %d 条，丢弃 %d 条\\N"):format(
            DENSITY_STATS.shrunk, DENSITY_STATS.dropped)
    end
    -- 黑名单统计（合并后过滤，实际丢弃时才显示）
    local blacklist_line = ""
    if BLACKLIST_STATS and BLACKLIST_STATS.dropped > 0 then
        blacklist_line = ("黑名单：过滤 %d 条\\N"):format(BLACKLIST_STATS.dropped)
    end
    -- 逐源标题汇总（会话模式含等待/失败条目，无会话模式列出已加载源；空表=无可显示源）
    local source_lines = source_status.format_lines()
    local source_part = ""
    if #source_lines > 0 then
        source_part = table.concat(source_lines, "\\N") .. "\\N"
    end
    -- 缓存来源标注（读完即清，避免同会话后续非缓存加载误带标记；on_unload 重置 DANMAKU 为兜底）
    local cache_tag = ""
    if DANMAKU.cache_hit == "cache" then
        cache_tag = "（缓存）"
    elseif DANMAKU.cache_hit == "stale" then
        cache_tag = "（离线缓存）"
    end
    DANMAKU.cache_hit = nil
    -- 有等待中的源 3s（随后到货会刷新），全部终态 6s（多源汇总留给用户核对标题）
    show_message(source_part .. merge_line .. blacklist_line .. density_line
        .. "共计" .. #COMMENTS .. "条弹幕", source_status.has_pending() and 3 or 6)
    if init then
        for _, line in ipairs(source_lines) do
            msg.info(line)
        end
        msg.info("弹幕加载成功" .. cache_tag .. "，共计" .. #COMMENTS .. "条弹幕")
    end
    mp.set_property_native(DANMAKU_COUNT, #COMMENTS)
    -- 弹幕源统计菜单开着时原地刷新（到货经上面 format_lines 的 settle 收敛后重建行；
    -- refresh_source_stats_menu 为 menu.lua 定义的全局，nil 守卫兼容部分模块单测环境）
    if refresh_source_stats_menu then refresh_source_stats_menu() end
end

-- 获取指定时间的延迟
-- 返回该时间点之前所有延迟段的总和
function get_delay_for_time(delay_segments, time)
    if not delay_segments or #delay_segments == 0 then return 0 end

    local segs = {}
    for i = 1, #delay_segments do segs[i] = delay_segments[i] end
    table.sort(segs, function(a, b) return a.start < b.start end)

    local applied_delay = 0
    for i = 1, #segs do
        local seg = segs[i]
        local delay = tonumber(seg.delay)
        if time >= seg.start and delay then
            applied_delay = applied_delay + delay
        else
            break
        end
    end
    return applied_delay
end

local function merge_delay_segments(segments)
    if not segments or #segments == 0 then return {} end

    local NEAREST_THRESHOLD = 10  -- 最邻近段合并阈值
    local MERGE_THRESHOLD = 30    -- 跨段合并阈值
    local EPSILON = 1e-6          -- 判断接近 0 的阈值

    table.sort(segments, function(a, b) return a.start < b.start end)

    local partially_merged = {}
    local i = 1
    while i <= #segments do
        local cur = segments[i]
        local next_seg = segments[i + 1]

        if next_seg and (next_seg.start - cur.start) <= NEAREST_THRESHOLD then
            local combined_delay = tonumber(cur.delay) + tonumber(next_seg.delay)
            if math.abs(combined_delay) > EPSILON then
                table.insert(partially_merged, {
                    start = cur.start,
                    delay = combined_delay
                })
            end
            i = i + 2
        else
            if math.abs(tonumber(cur.delay)) > EPSILON then
                table.insert(partially_merged, cur)
            end
            i = i + 1
        end
    end

    local merged = {}
    for _, seg in ipairs(partially_merged) do
        local merged_flag = false
        for idx, m in ipairs(merged) do
            if math.abs(seg.start - m.start) <= MERGE_THRESHOLD then
                m.delay = tonumber(m.delay) + tonumber(seg.delay)
                if math.abs(m.delay) <= EPSILON then
                    table.remove(merged, idx)
                end
                merged_flag = true
                break
            end
        end
        if not merged_flag then
            if math.abs(tonumber(seg.delay)) > EPSILON then
                table.insert(merged, {
                    start = seg.start,
                    delay = seg.delay
                })
            end
        end
    end

    table.sort(merged, function(a, b) return a.start < b.start end)
    return merged
end

function parse_delay_input(text)
    if not text then return nil end
    local s = tostring(text):gsub("%s+", "")
    if s == "" then return nil end
    -- XmYs 格式，允许负号在分钟部分
    local m, sec = string.match(s, "^(%-?%d+)m(%d+)s$")
    if m and sec then
        m = tonumber(m)
        sec = tonumber(sec)
        if not m or not sec then return nil end
        if m < 0 then sec = -sec end
        return m * 60 + sec
    end
    -- 普通数字（整数或小数），支持负数
    local n = tonumber(s)
    if n ~= nil then return n end
    return nil
end

local function set_danmaku_delay(dly, time, specific_source)
    if specific_source then
        local source = DANMAKU.sources[specific_source]
        if source and source.data and not source.blocked then
            -- 时间轴对齐已介入的源（align_shift 为数字）被手动设延迟：置 pin 让后续
            -- 管线重建保留当前校正量不再重投票——否则手动增量会被当成新漂移整源平移
            -- 回基准、微调静默失效；输入 0 清空延迟同时解除 pin，恢复自动对齐
            if dly == 0 then
                source.align_pinned = nil
            elseif type(source.align_shift) == "number" then
                source.align_pinned = true
            end
            source.delay_segments = source.delay_segments or {}
            if dly == 0 then
                source.delay_segments = {}
            elseif time then
                table.insert(source.delay_segments, {start = time, delay = dly})
            else
                table.insert(source.delay_segments, {start = 0, delay = dly})
            end
            source.delay = nil
            source.delay_segments = merge_delay_segments(source.delay_segments)
            add_source_to_history(specific_source, source)
            -- B站文件夹记忆：镜像延迟设置，跨集继承偏移
            sync_bilibili_series_source(specific_source, { delay_segments = source.delay_segments })
        end
    else
        for url, source in pairs(DANMAKU.sources) do
            if source.data and not source.blocked then
                if dly == 0 then
                    source.align_pinned = nil
                elseif type(source.align_shift) == "number" then
                    source.align_pinned = true
                end
                source.delay_segments = source.delay_segments or {}
                if dly == 0 then
                    source.delay_segments = {}
                elseif time then
                    table.insert(source.delay_segments, {start = time, delay = dly})
                else
                    table.insert(source.delay_segments, {start = 0, delay = dly})
                end

                source.delay = nil
                source.delay_segments = merge_delay_segments(source.delay_segments)
                add_source_to_history(url, source)
                sync_bilibili_series_source(url, { delay_segments = source.delay_segments })
            end
        end
    end

    if not specific_source then
        if dly == 0 then
            DELAY = 0
        else
            DELAY = DELAY + dly
        end
    end

    if ENABLED and COMMENTS ~= nil then
        render()
    end

    -- 防抖：批量重建 ASS 事件并渲染，避免频繁变更导致重复重建。
    -- 走重建调度器与到货防抖共用 timer 槽：延迟调整与到货同时发生时
    -- 后到请求覆盖先到 pending（两者都是全量重建+渲染），绝不双跑
    sched.request({
        window = 0.1,
        run = function()
            if convert_danmaku_to_ass_events then
                convert_danmaku_to_ass_events(true)
            end
            render()
        end,
    })

    if specific_source then
        local source = DANMAKU.sources[specific_source]
        local source_delay = get_delay_for_time(source and source.delay_segments, time or 0)
        -- 与延迟菜单同口径：显示手动延迟 + 时间轴对齐校正量的合计（对齐介入时
        -- 只报手动段会仍是 0.0 秒，看不出该源实际被整体平移过）
        local align = (source and type(source.align_shift) == "number") and source.align_shift or 0
        local suffix = align ~= 0 and string.format('（含时间轴对齐%+.1f）', align) or ''
        show_message('设置弹幕源延迟: ' .. string.format("%.1f", source_delay + align + 1e-10) .. ' s' .. suffix)
    else
        show_message('设置弹幕延迟: ' .. string.format("%.1f", DELAY + 1e-10) .. ' s')
        mp.set_property_native(DELAY_PROPERTY, DELAY)
    end
end

local function clear_source()
    local path = mp.get_property("path")
    local history_json = read_file(HISTORY_PATH)

    if not path or not history_json then return end

    local history = utils.parse_json(history_json) or {}
    if history[path] == nil then return end

    history[path] = nil
    write_json_file(HISTORY_PATH, history)

    for url, source in pairs(DANMAKU.sources) do
        if source.from == "user_custom" then
            DANMAKU.sources[url] = nil
            -- 统计台账同步移除（已重置的源不再出现在弹幕源统计）
            source_status.remove(url)
        end
    end

    load_danmaku(false)

    show_message("已重置当前视频所有弹幕源更改", 3)
    msg.verbose("已重置当前视频所有弹幕源更改")
end

function write_history(episodeid, api_server)
    local history = {}
    local path = mp.get_property("path")
    local dir = get_parent_directory(path)
    local fname = mp.get_property('filename/no-ext')
    local episodeNumber = 0
    if episodeid then
        episodeNumber = tonumber(episodeid) % 1000
    elseif DANMAKU.extra then
        episodeNumber = DANMAKU.extra.episodenum
    end

    if is_protocol(path) then
        local title, season_num, episod_num = parse_title()
        if title and episod_num then
            if season_num then
                dir = title .." Season".. season_num
            else
                dir = title
            end
            fname = url_decode(mp.get_property("media-title"))
            episodeNumber = episod_num
        end
    end

    if dir ~= nil then
        local history_json = read_file(HISTORY_PATH)
        if history_json ~= nil then
            history = utils.parse_json(history_json) or {}
        end
        local old = history[dir] or {}
        -- 多源并行记忆：直连源选择记入 extras 表（同 kind 替换），旧格式单 extra 迁移；
        -- dandanplay 选择（episodeid 非 nil）不合并当前 DANMAKU.extra（防全局残留污染新文件夹），
        -- 详见 modules/history_merge.lua（含单元测试）
        -- extras[].fname / episodeId_fname 为各记忆条目的文件名锚点：多源异步续载时快源先
        -- 到先写会把全局 fname 移到当前集，慢源 episodenum/episodeId 仍停在旧集，续载差值
        -- 必须逐锚推算（见 dandanplay_flow 的 anchor_delta）
        local extras = hmerge.merge_extras(old,
            episodeid and nil or DANMAKU.extra, fname)
        history[dir] = {}
        history[dir].fname = fname
        history[dir].source = DANMAKU.source
        history[dir].animeTitle = DANMAKU.anime
        history[dir].episodeTitle = DANMAKU.episode
        history[dir].episodeNumber = episodeNumber
        if episodeid then
            history[dir].episodeId = episodeid
            history[dir].episodeId_fname = fname
        elseif old.episodeId then
            -- 直连源选择不挤掉 dandanplay 的集数记录（多源并存续载的依据）；
            -- 锚点也保持 dandanplay 自己的（episodeId 未变，锚不得随直连源移动）
            history[dir].episodeId = old.episodeId
            history[dir].episodeId_fname = old.episodeId_fname
        end
        if #extras > 0 then
            history[dir].extras = extras
        end
        if api_server then
            history[dir].api_server = api_server
        end
        if old.bilibili ~= nil then
            history[dir].bilibili = old.bilibili
        end
        write_json_file(HISTORY_PATH, history)
    end
end

function remove_source_from_history(rm_source)
    local history_json = read_file(HISTORY_PATH)
    local path = mp.get_property("path")

    if is_protocol(path) then
        path = remove_query(path)
    end

    if history_json then
        local history = utils.parse_json(history_json) or {}

        if history[path] ~= nil and history[path]["sources"] ~= nil then
            for source in pairs(history[path]["sources"]) do
                if source == rm_source then
                    history[path]["sources"][source] = nil
                    break
                end
            end
        end

        write_json_file(HISTORY_PATH, history)
    end
end

function add_source_to_history(add_url, add_source)
    local history_json = read_file(HISTORY_PATH)
    local path = mp.get_property("path")

    if is_protocol(path) then
        path = remove_query(path)
    end

    local history = {}
    if history_json then
        history = utils.parse_json(history_json) or {}
    end

    history[path] = history[path] or {}
    history[path]["sources"] = history[path]["sources"] or {}
    history[path]["sources"][add_url] = history[path]["sources"][add_url] or {}

    local record = history[path]["sources"][add_url]
    record.from = add_source.from or "user_custom"
    record.blocked = add_source.blocked or false
    if add_source.provider ~= nil then
        record.provider = add_source.provider
    end
    -- 源标题（loader 同步段捕获经 add_danmaku_source 传入）：只补不擦，老记录无此字段回退显示 URL
    if add_source.anime_title ~= nil then
        record.anime_title = add_source.anime_title
    end
    if add_source.episode_title ~= nil then
        record.episode_title = add_source.episode_title
    end

   local delay_segments = shallow_copy(add_source.delay_segments or {})
    if #delay_segments > 0 then
        record.delay_segments = merge_delay_segments(delay_segments)
        if #record.delay_segments == 0 then
            record.delay_segments = nil
        end
    else
        record.delay_segments = nil
    end

    record.delay = nil
    write_json_file(HISTORY_PATH, history)
end

function read_danmaku_source_record(path)
    if is_protocol(path) then
        path = remove_query(path)
    end

    local history_json = read_file(HISTORY_PATH)
    if not history_json then return end

    local history = utils.parse_json(history_json) or {}
    local record = history[path]

    if not record or not record.sources then return end

    local sources = record.sources
    local upgraded_sources = {}

    if is_nested_table(sources) then
        for source, data in pairs(sources) do
            local from = data.from or "user_custom"
            local blocked = data.blocked or false
            local delay_segments = shallow_copy(data.delay_segments or {})
            if data.delay ~= nil then
                for i = #delay_segments, 1, -1 do
                    if delay_segments[i].start == 0 then
                        table.remove(delay_segments, i)
                    end
                end
                table.insert(delay_segments, 1, { start = 0, delay = tonumber(data.delay) })
            end
            if #delay_segments > 0 then
                delay_segments = merge_delay_segments(delay_segments)
            else
                delay_segments = nil
            end

            DANMAKU.sources[source] = {
                from = from,
                blocked = blocked,
                delay_segments = delay_segments,
                from_history = true,
                provider = data.provider,
                anime_title = data.anime_title,
                episode_title = data.episode_title,
            }
        end
    else
        for _, raw in ipairs(sources) do
            local source = raw
            local blocked = false
            local from = raw:match("<(.-)>")
            local delay = raw:match("{{(.-)}}")

            source = source:gsub("<.->", ""):gsub("{{.-}}", "")

            if source:match("^%-") then
                source = source:sub(2)
                blocked = true
                from = from or "api_server"
            end

            local delay_segments = nil
            if delay ~= nil then
                delay_segments = {
                    { start = 0, delay = tonumber(delay) }
                }
            end

            DANMAKU.sources[source] = {
                from = from or "user_custom",
                blocked = blocked,
                delay_segments = delay_segments,
                from_history = true,
            }

            upgraded_sources[source] = shallow_copy(DANMAKU.sources[source])
        end

        if next(upgraded_sources) then
            record.sources = upgraded_sources
            write_json_file(HISTORY_PATH, history)
        end
    end
end

local function get_save_danmaku_output(path, filename)
    if not path or not filename then return nil end

    local custom_dir = options.save_danmaku_path ~= "" and
        mp.command_native({"expand-path", options.save_danmaku_path}) or nil
    local is_url = is_protocol(path)
    local mode = options.save_danmaku_path_mode
    local dir = nil

    if mode ~= "url" and mode ~= "all" then
        mode = "local"
    end

    if custom_dir and (mode == "all" or (mode == "url" and is_url) or (mode == "local" and not is_url)) then
        local output_name = sanitize_filename(filename)
        if not is_url then
            dir = get_parent_directory(path)
            local _, parent_name = dir and utils.split_path(dir:sub(1, -2))
            if parent_name and parent_name ~= "" then
                output_name = sanitize_filename(parent_name .. "_" .. filename)
            end
        end
        return utils.join_path(custom_dir, output_name .. ".xml")
    end

    if is_url then
        return nil
    end

    dir = get_parent_directory(path)
    if not dir then
        return nil
    end
    return utils.join_path(dir, filename .. ".xml")
end

-- 视频播放时保存弹幕
function save_danmaku(not_forced)
    local path = mp.get_property("path")
    local filename = is_protocol(path) and mp.get_property("media-title") or mp.get_property('filename/no-ext')
    local danmaku_out = get_save_danmaku_output(path, filename)
    if not danmaku_out or (not file_exists(danmaku_out)
    and not is_writable(danmaku_out)) then
        show_message("此弹幕文件不支持保存至本地")
        msg.warn("此弹幕文件不支持保存至本地")
    else
        if not_forced and file_exists(danmaku_out) then
            show_message("已存在同名弹幕文件：" .. danmaku_out)
            msg.info("已存在同名弹幕文件：" .. danmaku_out)
            return
        else
            convert_danmaku_to_xml(danmaku_out)
        end
    end
end

-- 加载弹幕。第三参 arrival=true 标记「弹幕源到货」类调用（下载回调）：
-- 首源立即重建（用户无感延迟），防抖窗口内后续到货合并为一次全量重建——
-- 此前每源到货各跑一遍完整管线（含 pakku 合并），双源场景加载期突发两次卡顿。
-- 菜单/手动路径（默认 arrival=nil）不走防抖，改样式立刻见效。
local ARRIVAL_WINDOW = 0.2
local arrival_ctx = { from_menu = nil, no_osd = nil }

function load_danmaku(from_menu, no_osd, arrival)
    if not ENABLED then return end
    local function do_rebuild(fm, nos)
        convert_danmaku_to_ass_events()
        render_danmaku(fm, nos)
    end
    if arrival then
        if not sched.has_pending() and sched.idle(ARRIVAL_WINDOW) then
            sched.run_now(function() do_rebuild(from_menu, no_osd) end)
        else
            -- 合并窗口内多源的 from_menu/no_osd（布尔 OR：任一请求带即生效）
            arrival_ctx.from_menu = arrival_ctx.from_menu or from_menu
            arrival_ctx.no_osd = arrival_ctx.no_osd or no_osd
            sched.request({
                window = ARRIVAL_WINDOW,
                run = function()
                    local fm, nos = arrival_ctx.from_menu, arrival_ctx.no_osd
                    arrival_ctx.from_menu, arrival_ctx.no_osd = nil, nil
                    do_rebuild(fm, nos)
                end,
            })
        end
        return
    end
    do_rebuild(from_menu, no_osd)
end

function load_danmaku_for_url(path)
    -- URL 直播路径登记统计台账（不经 add_danmaku_source，无 ensure 则失败不留痕）；
    -- 回调记录终态，成功路径由落源 + settle 自动完成检测接管
    local function record(ok, no_data, reason)
        if ok then return end
        local label = provider_label_from_url(path)
        if no_data then
            source_status.mark_empty(path, reason or "该集无弹幕", label)
        else
            source_status.mark_failed(path, reason or "加载失败", label)
        end
    end
    source_status.ensure(path, provider_label_from_url(path))

    if path:find('bilibili.com') or path:find('bilivideo.c[nom]+') then
        load_danmaku_for_bilibili(path, record)
        return
    end

    if path:find('bahamut.akamaized.net') then
        load_danmaku_for_bahamut(path, record)
        return
    end

    local title, season_num, episod_num = parse_title()
    local filename = url_decode(mp.get_property("media-title"))
    local episod_number = nil
    if title and episod_num then
        if season_num then
            dir = title .." Season".. season_num
            episod_number = episod_num
        else
            dir = title
        end
        auto_load_danmaku(path, dir, filename, episod_number)
        addon_danmaku(dir, false)
        return
    end
    get_danmaku_with_hash(filename, path)
    addon_danmaku()
end

-- 自动加载上次匹配的弹幕
function auto_load_danmaku(path, dir, filename, number)
    if dir == nil then return end
    local history_json = read_file(HISTORY_PATH)
    if history_json == nil then
        get_danmaku_with_hash(filename, path)
        return
    end
    local history = utils.parse_json(history_json) or {}
    -- 1.判断父目录记录是否存在
    local history_dir = history[dir]
    if history_dir == nil then
        get_danmaku_with_hash(filename, path)
        return
    end

    -- 2.如果存在，则获取number和id（弹弹play/extra 记忆流程，原逻辑提为闭包）
    local function dandanplay_flow()
        DANMAKU.anime = history_dir.animeTitle
        local episode_number = history_dir.episodeTitle and history_dir.episodeTitle:match("%d+")
        local history_number = history_dir.episodeNumber
        local history_id = history_dir.episodeId
        local history_fname = history_dir.fname
        local history_api_server = history_dir.api_server
        local playing_number = nil

        if history_fname then
            if filename ~= history_fname then
                if number then
                    playing_number = number
                else
                    history_number, playing_number = get_episode_number(filename, history_fname)
                end
            else
                playing_number = history_number
            end
        else
            playing_number = get_episode_number(filename)
        end
        if playing_number ~= nil then
            local x = playing_number - history_number --获取集数差值（全局锚：fname/episodeNumber）
            -- 每源锚点差值：多源异步续载时快源先 write_history 已把全局锚移到当前集，
            -- 慢源的 episodenum/episodeId 仍停在旧集（重载/换集后全局差值对慢源失效），
            -- 故逐条按各自 fname 锚独立推算；老记录无锚回退全局差值（URL 场景 number
            -- 显式给出时同样走全局，行为与旧版一致）
            local function anchor_delta(anchor_fname)
                if number then return x end
                return hmerge.anchor_delta(get_episode_number, filename, anchor_fname, x)
            end
            local x_ddp = anchor_delta(history_dir.episodeId_fname)
            DANMAKU.episode = episode_number and string.format("第%s话", episode_number + x_ddp) or history_dir.episodeTitle
            DANMAKU.api_server = history_api_server or nil

            -- 多源并行续载：extras 表（各直连源一条）+ dandanplay 的 episodeId 同时恢复；
            -- 旧格式单 extra 迁移为单元素表（modules/history_merge.lua）。各源集数编号语义一致
            --（列表序），差值按各源 fname 锚独立推算（anchor_delta）
            local extras_list = hmerge.read_extras(history_dir)

            if history_id ~= nil or #extras_list > 0 then
                -- 汇总会话：extras 各源登记等待行（dandanplay 条目由 fetch_danmaku 以真实
                -- comment URL 追加），到货/失败经 source_status 动态刷新同一 OSD 位置
                local pending = {}
                for _, ex in ipairs(extras_list) do
                    local kind = ex.kind or "360kan"
                    pending[#pending + 1] = {
                        key = "extra:" .. kind,
                        provider = source_status.kind_provider_label(kind),
                        anime = ex.title,
                    }
                end
                source_status.begin(pending)
                msg.verbose("自动加载上次匹配的弹幕")
                if history_id then
                    local tmp_id = tostring(x_ddp + history_id)
                    set_episode_id(tmp_id, nil, nil,
                        {anime = DANMAKU.anime, episode = DANMAKU.episode})
                end
                for _, ex in ipairs(extras_list) do
                    local episodenum = ex.episodenum + anchor_delta(ex.fname)
                    -- extra 记录按 kind 分发：旧记录无 kind 等价 360kan（向后兼容）
                    local kind = ex.kind or "360kan"
                    if kind == "qq" then
                        resume_tencent_episode(ex, episodenum)
                    elseif kind == "maccms" then
                        resume_maccms_episode(ex, episodenum)
                    elseif kind == "youku" then
                        resume_youku_episode(ex, episodenum)
                    elseif kind == "mgtv" then
                        resume_mgtv_episode(ex, episodenum)
                    elseif kind == "bilibili" then
                        resume_bilibili_episode(ex, episodenum)
                    elseif kind == "bahamut" then
                        resume_bahamut_episode(ex, episodenum)
                    elseif kind == "animeko" then
                        resume_animeko_episode(ex, episodenum)
                    elseif kind == "maiduidui" then
                        resume_maiduidui_episode(ex, episodenum)
                    elseif kind == "iqiyi" then
                        resume_iqiyi_episode(ex, episodenum)
                    elseif kind == "acf" then
                        resume_acfun_episode(ex, episodenum)
                    elseif kind == "ezd" then
                        resume_ezdmw_episode(ex, episodenum)
                    elseif kind == "ggl" then
                        resume_ggl_episode(ex, episodenum)
                    elseif kind == "ayf" then
                        resume_aiyifan_episode(ex, episodenum)
                    elseif kind == "cyc" then
                        resume_cyc_episode(ex, episodenum)
                    else
                        get_details(ex.class, ex.id, ex.site,
                            ex.title, ex.year, ex.number, episodenum)
                    end
                end
            else
                -- 记录无 episodeId/extra（如仅B站文件夹记忆）→ 走哈希匹配
                get_danmaku_with_hash(filename, path)
            end
        else
            get_danmaku_with_hash(filename, path)
        end
    end

    -- 3.B站合集文件夹记忆：add 模式与弹弹play流程叠加，first 模式匹配成功则跳过
    local bl_records = history_dir.bilibili
    if bl_records ~= nil and next(bl_records) ~= nil
        and options.bilibili_series_memory ~= "off" then
        autoload_bilibili_series(path, dir, bl_records, dandanplay_flow)
    else
        dandanplay_flow()
    end
end

function init(path)
    if not path then return end
    local dir = get_parent_directory(path)
    local filename = mp.get_property('filename/no-ext')
    local video = mp.get_property_native("current-tracks/video")
    local duration = mp.get_property_number("duration", 0)
    if not video or video["image"] or video["albumart"] or duration < 60 then
        msg.info("不支持的播放内容（非视频）")
        return
    end
    if is_protocol(path) then
        load_danmaku_for_url(path)
    end
    if dir and filename then
        local danmaku_xml = utils.join_path(dir, filename .. ".xml")
        if file_exists(danmaku_xml) then
            add_danmaku_source_local(danmaku_xml, true)
        else
            auto_load_danmaku(path, dir, filename)
            addon_danmaku(dir, true)
        end
    end
end

mp.register_event("file-loaded", function()
    source_status.reset()
    local path = mp.get_property("path")
    local dir = get_parent_directory(path)
    local filename = mp.get_property('filename/no-ext')
    local video = mp.get_property_native("current-tracks/video")
    local fps = mp.get_property_number("container-fps", 0)
    local duration = mp.get_property_number("duration", 0)
    if not video or video["image"] or video["albumart"] or fps < 23 or duration < 60 then
        return
    end

    read_danmaku_source_record(path)

    if not get_danmaku_visibility() then
        return
    end

    if options.autoload_for_url and is_protocol(path) then
        ENABLED = true
        load_danmaku_for_url(path)
    end

    if filename == nil or dir == nil then
        return
    end
    local danmaku_xml = utils.join_path(dir, filename .. ".xml")
    if options.autoload_local_danmaku then
        if file_exists(danmaku_xml) then
            ENABLED = true
            add_danmaku_source_local(danmaku_xml)
            return
        end
    end

    if options.auto_load then
        ENABLED = true
        auto_load_danmaku(path, dir, filename)
        addon_danmaku(dir, false)
        return
    end

    if ENABLED and COMMENTS == nil and not is_async_running() then
        init(path)
    end
end)

-------------- 键位绑定 --------------
mp.add_key_binding(options.open_search_danmaku_menu_key, "open_search_danmaku_menu", function()
    mp.commandv("script-message", "open_search_danmaku_menu")
end)
mp.add_key_binding(options.show_danmaku_keyboard_key, "show_danmaku_keyboard", function()
    mp.commandv("script-message", "show_danmaku_keyboard")
end)
if options.density_timeline_key ~= nil and options.density_timeline_key ~= "" then
    mp.add_key_binding(options.density_timeline_key, "toggle_density_timeline_key", function()
        mp.commandv("script-message", "toggle_density_timeline")
    end)
end

-------------- 事件注册 --------------
mp.register_script_message("danmaku-delay", function(...)
    local commands = {...}
    local delay_str, time_str = commands[1], commands[2]
    local source_arg = commands[3]
    local dly = parse_delay_input(delay_str)
    local time = time_str and tonumber(time_str)
    if type(dly) ~= "number" then
        show_message("参数错误：缺少有效的延迟秒数", 3)
        return
    end
    if source_arg and source_arg ~= "nil" then
        set_danmaku_delay(dly, time, source_arg)
    else
        set_danmaku_delay(dly, time)
    end
end)

mp.register_script_message("show_danmaku_keyboard", function()
    ENABLED = not ENABLED
    if ENABLED then
        toggle_danmaku_switch("on")

        if COMMENTS == nil then
            show_message("加载弹幕初始化...", 3)
            set_danmaku_visibility(true)
            local path = mp.get_property("path")
            init(path)
        else
            show_loaded()
            show_danmaku_func()
        end
    else
        show_message("关闭弹幕", 2)
        toggle_danmaku_switch("off")
        hide_danmaku_func()
    end
end)

mp.register_script_message("auto_load_fallback", function()
    -- FALLBACK_TRIGGER 在 on_unload 时重置（render.lua），保证每个文件各有一次自动兜底机会；
    -- 此前误用未声明的 fallback_triggered，导致整个 mpv 会话只触发一次
    if not FALLBACK_TRIGGER and options.auto_fallback_search and COMMENTS == nil then
        FALLBACK_TRIGGER = true
        msg.info("自动加载弹幕失败，自动弹出搜索框")
        mp.commandv("script-message", "open_search_danmaku_menu")
    end
end)

mp.register_script_message("check-update", check_for_update)
mp.register_script_message("clear-source", clear_source)
mp.register_script_message("clear-bilibili-record", function()
    local path = mp.get_property("path")
    if not path or is_protocol(path) then return end
    local dir = get_parent_directory(path)
    if dir and clear_bilibili_series_record(dir) then
        show_message("已清除本文件夹的B站弹幕记忆", 3)
    else
        show_message("本文件夹无B站弹幕记忆", 3)
    end
end)
mp.register_script_message("clear-danmaku-cache", function()
    local n = danmaku_cache.clear()
    if n > 0 then
        show_message(string.format("已清空弹幕缓存（%d 项）", n), 3)
    else
        show_message("弹幕缓存为空或未启用", 3)
    end
end)
mp.register_script_message("immediately_save_danmaku", save_danmaku)
mp.register_script_message("open_source_delay_menu", open_delay_menu)
mp.register_script_message("open_search_danmaku_menu", open_input_menu)
mp.register_script_message("open_add_source_menu", open_add_menu)
mp.register_script_message("open_add_total_menu", open_add_total_menu)
mp.register_script_message("open_source_stats_menu", open_source_stats_menu)
mp.register_script_message("show_danmaku_count", show_loaded)
