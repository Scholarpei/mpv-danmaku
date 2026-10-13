-- modified from https://github.com/rkscv/danmaku/blob/main/danmaku.lua
local msg = require('mp.msg')
local utils = require("mp.utils")
local unpack = unpack or table.unpack

local osd_width, osd_height, pause = 0, 0, true
local time_pos_observer_active = false
local overlay_low = mp.create_osd_overlay('ass-events')
local overlay_high = mp.create_osd_overlay('ass-events')

-- ass_prefix 值比较缓存：bold/fontname/opacity/outline/shadow 等样式菜单只改 options
-- 不重建管线（靠 render 每帧读 options 生效），故失效必须基于字段值比较而非重建打标。
-- fontsize（经 ratio 调整）也在比较内，窗口比例变化时联动重算并清空字号前缀缓存。
-- 六字段直接值比较（无字符串拼接——拼接本身每帧的成本会盖过稀疏窗口的收益）
local pcache = { fontname = nil, fontsize = nil, opacity = nil,
    outline = nil, shadow = nil, bold = nil }
local prefix_value = nil
local fs_prefix_cache = {}
-- high 层（顶/底固定弹幕）上次 data：窗口内文本不变，整串比对相同则跳过 update
-- （镜像 density_timeline 的签名去重范本）。overlay:remove 后必须置 nil，否则重显首帧不更新。
local last_high_data = nil

-- 纯计算：pos → (low 字符串, high 字符串)。overlay 操作留在 render()，供测试/基准直接驱动。
-- 每条弹幕的常量变换（剥 move/实体、fs 放大、an 标签）已在构建期 bake 进
-- event.render_body / render_fixed，此处主循环零正则，仅滚动弹幕剩一次坐标 format。
function build_visible_strings(pos)
    if COMMENTS == nil then return nil, nil end

    local fontname = options.fontname
    local fontsize = options.fontsize
    local opacity = tonumber(options.opacity)

    local width, height = 1920, 1080
    local ratio = osd_width / osd_height
    if width / height < ratio then
        height = width / ratio
        fontsize = options.fontsize - ratio * 2
    end

    local ass_events_low = {}
    local ass_events_high = {}
    local max_display = math.max(options.scrolltime, options.fixtime)
    local window_start = pos - max_display

    -- 跳过已结束的弹幕
    local lo = binary_search(COMMENTS, window_start, function(item) return item.start_time end)

    if fontname ~= pcache.fontname or fontsize ~= pcache.fontsize or opacity ~= pcache.opacity
        or options.outline ~= pcache.outline or options.shadow ~= pcache.shadow
        or options.bold ~= pcache.bold then
        pcache.fontname = fontname
        pcache.fontsize = fontsize
        pcache.opacity = opacity
        pcache.outline = options.outline
        pcache.shadow = options.shadow
        pcache.bold = options.bold
        local alpha = string.format("%02X", (1 - (opacity or 0)) * 255)
        prefix_value = string.format("{\\rDefault\\fn%s\\fs%d\\c&HFFFFFF&\\alpha&H%s\\bord%s\\shad%s\\b%s\\q2}",
            fontname, fontsize, alpha, options.outline, options.shadow, options.bold and "1" or "0")
        fs_prefix_cache = {}
    end
    local ass_prefix = prefix_value

    local displayarea = height * options.displayarea
    local configured_size = tonumber(options.fontsize) or fontsize

    for i = lo, #COMMENTS do
        local event = COMMENTS[i]
        if not event then break end

        if event.start_time > pos then break end  -- 后续弹幕提前退出
        if event.end_time >= pos then
            local text
            if event.move then
                -- 滚动弹幕：坐标插值（算式与旧实现逐字一致）+ 预计算静态体
                local move = event.move
                local x1, y1, x2, y2 = move[1], move[2], move[3], move[4]
                local duration = event.end_time - event.start_time  --mean: options.scrolltime
                local progress = (pos - event.start_time) / duration  -- 移动进度 [0, 1]
                local current_x = tonumber(x1 + (x2 - x1) * progress)
                local current_y = tonumber(y1 + (y2 - y1) * progress)
                if current_y <= displayarea then
                    text = string.format("{\\pos(%.1f,%.1f)\\an%s}%s",
                        current_x, current_y, event.render_an or "8", event.render_body)
                end
            else
                -- 顶/底固定弹幕：完整文本已预计算（含 an 标签），零拼接
                local fixed_pos = event.pos
                local current_y = fixed_pos and fixed_pos[2]
                if current_y and not (tonumber(current_y) > displayarea) then
                    text = event.render_fixed
                end
            end

            if text then
                -- 字号前缀按调整后字号整数键缓存（构建期 font_size 种类有限）
                local event_font_prefix = ""
                if event.font_size then
                    local adjusted_size = math.max(1, math.floor(event.font_size + fontsize - configured_size))
                    event_font_prefix = fs_prefix_cache[adjusted_size]
                    if not event_font_prefix then
                        event_font_prefix = string.format("{\\fs%d}", adjusted_size)
                        fs_prefix_cache[adjusted_size] = event_font_prefix
                    end
                end
                local ass_text = ass_prefix .. event_font_prefix .. text
                if event.layer == nil or tonumber(event.layer) == 0 then
                    ass_events_low[#ass_events_low + 1] = ass_text
                else
                    ass_events_high[#ass_events_high + 1] = ass_text
                end
            end
        end
    end

    return table.concat(ass_events_low, '\n'), table.concat(ass_events_high, '\n'), width, height
end

function render(pos_arg)
    if COMMENTS == nil then return end

    local pos, err
    if pos_arg == nil then
        pos, err = mp.get_property_number('time-pos')
        if err ~= nil then
            return msg.error(err)
        end
    else
        pos = pos_arg
    end

    if not pos then
        overlay_low:remove()
        overlay_high:remove()
        last_high_data = nil
        return
    end

    local low_data, high_data, width, height = build_visible_strings(pos)
    if low_data == nil then return end

    -- 低层（滚动）每帧必变（坐标移动），不做比对直接更新
    overlay_low.res_x = width
    overlay_low.res_y = height
    overlay_low.z = 0
    overlay_low.data = low_data
    overlay_low:update()

    -- 高层（顶/底固定）窗口内文本不变，data 未变跳过重传
    if high_data ~= last_high_data then
        overlay_high.res_x = width
        overlay_high.res_y = height
        overlay_high.z = 1
        overlay_high.data = high_data
        overlay_high:update()
        last_high_data = high_data
    end
end

local function time_pos_callback(_, time_pos)
    if time_pos then
        render(time_pos)
    else
        overlay_low:remove()
        overlay_high:remove()
        last_high_data = nil
    end
end

local function start_time_observer()
    if not time_pos_observer_active then
        mp.observe_property('time-pos', 'number', time_pos_callback)
        time_pos_observer_active = true
    end
end

local function stop_time_observer()
    if time_pos_observer_active then
        mp.unobserve_property(time_pos_callback)
        time_pos_observer_active = false
    end
end

function render_danmaku(from_menu, no_osd)
    if ENABLED and (from_menu or get_danmaku_visibility()) then
        if not no_osd then
            show_loaded(true)
        end
        toggle_danmaku_switch("on")
        show_danmaku_func()
    else
        show_message("")
        hide_danmaku_func()
    end
end

local function filter_state(label, name)
    local filters = mp.get_property_native("vf")
    for _, filter in pairs(filters) do
        if filter.label == label or filter.name == name
        or filter.params[name] ~= nil then
            return true
        end
    end
    return false
end

function show_danmaku_func()
    mp.set_property_bool(HAS_DANMAKU, true)
    set_danmaku_visibility(true)
    render()
    if not pause then
        start_time_observer()
    end
    if options.vf_fps then
        local display_fps = mp.get_property_number('display-fps')
        local video_fps = mp.get_property_number('estimated-vf-fps')
        if (display_fps and display_fps < 58) or (video_fps and video_fps > 58) then
            return
        end
        if not filter_state("danmaku", "fps") then
            mp.commandv("vf", "append", string.format("@danmaku:fps=fps=%s", options.fps))
        end
    end
end

function hide_danmaku_func()
    stop_time_observer()
    mp.set_property_bool(HAS_DANMAKU, false)
    set_danmaku_visibility(false)
    overlay_low:remove()
    overlay_high:remove()
    last_high_data = nil
    if filter_state("danmaku") then
        mp.commandv("vf", "remove", "@danmaku")
    end
end

local message_overlay = mp.create_osd_overlay('ass-events')
local message_timer = mp.add_timeout(3, function()
    message_overlay:remove()
end, true)

function show_message(text, time)
    message_timer.timeout = time or 3
    message_timer:kill()
    message_overlay:remove()
    local message = string.format("{\\an%d\\pos(%d,%d)}%s", options.message_anlignment,
       options.message_x, options.message_y, text)
    local width, height = 1920, 1080
    local ratio = osd_width / osd_height
    if width / height < ratio then
        height = width / ratio
    end
    message_overlay.res_x = width
    message_overlay.res_y = height
    message_overlay.data = message
    message_overlay:update()
    message_timer:resume()
end

mp.observe_property('osd-width', 'number', function(_, value) osd_width = value or osd_width end)
mp.observe_property('osd-height', 'number', function(_, value) osd_height = value or osd_height end)
mp.observe_property('pause', 'bool', function(_, value)
    if value ~= nil then
        pause = value
    end
    if ENABLED then
        if pause then
            stop_time_observer()
        elseif COMMENTS ~= nil then
            start_time_observer()
        end
    end
end)

mp.register_event('playback-restart', function(event)
    if event.error then
        return msg.error(event.error)
    end
    if ENABLED and COMMENTS ~= nil then
        render()
    end
end)

mp.add_hook("on_unload", 50, function()
    FALLBACK_TRIGGER, COMMENTS, DELAY = false, nil, 0
    stop_time_observer()
    -- 清掉挂起的到货/延迟防抖重建，防换集后旧 timer 重建已清空的 DANMAKU
    if sched then sched.cancel() end
    overlay_low:remove()
    overlay_high:remove()
    last_high_data = nil
    mp.set_property_native(DELAY_PROPERTY, 0)
    if filter_state("danmaku") then
        mp.commandv("vf", "remove", "@danmaku")
    end

    local files_to_remove = {
        file1 = utils.join_path(DANMAKU_PATH, "temp-" .. PID .. ".mp4"),
    }

    if options.save_danmaku then
        save_danmaku(true)
    end

    for _, file in pairs(files_to_remove) do
        if file_exists(file) then
            os.remove(file)
        end
    end

    DANMAKU = {sources = {}, count = 1}
    if source_status then source_status.reset() end
    -- 清空选集菜单多选会话注册表，避免换集后恢复过期高亮
    if reset_details_session then reset_details_session() end
    mp.set_property_native(DANMAKU_COUNT, 0)
    mp.set_property_bool(HAS_DANMAKU, false)
end)
