-- Session-only final offset. Source calibration and layout never read this value.
local utils = require('mp.utils')
local M = {}
local seconds, path = 0, mp.get_property('path')
local original_events, published
local property = 'user-data/' .. mp.get_script_name() .. '/danmaku-global-delay'

local function finite(value)
    return type(value) == 'number' and value == value and math.abs(value) < math.huge
end
local function sync_path()
    local current = mp.get_property('path')
    if current ~= path then
        path, seconds, original_events, published = current, 0, nil, nil
        mp.set_property_native(property, 0)
    end
end
function M.get()
    sync_path()
    return seconds
end
local function refresh_density()
    local density = package.loaded['modules/density_timeline']
    if density and density.refresh then density.refresh() end
end
local function apply()
    local result = {}
    for _,event in ipairs(original_events or {}) do
        local start = event.start_time + seconds
        -- Keep the unshifted events so returning to zero restores everything.
        -- Never clamp negative starts: that would pile unrelated comments at 0.
        if start >= 0 then
            local copy = {}
            for k,v in pairs(event) do copy[k] = v end
            copy.start_time = start
            copy.end_time = event.end_time + seconds
            copy.delay = (event.delay or 0) + seconds
            result[#result + 1] = copy
        end
    end
    COMMENTS, published = result, result
    refresh_density()
end
function M.publish(events)
    sync_path()
    original_events = events
    apply()
end
function M.set(value)
    if not finite(value) then return false end
    sync_path()
    seconds = value == 0 and 0 or value
    mp.set_property_native(property, seconds)
    if original_events and COMMENTS == published then
        apply()
        if ENABLED and type(render_danmaku) == 'function' then render_danmaku(true, true) end
    end
    return true
end
function M.adjust(delta)
    if not finite(delta) then return false end
    local value = M.get() + delta
    if not finite(value) then return false end
    return M.set(value)
end
local function report(ok)
    if not ok then show_message('请输入有效的整体偏移秒数', 3);return end
    local value = M.get()
    local direction = value < 0 and '提前' or (value > 0 and '延后' or '已归零')
    show_message(string.format('弹幕整体偏移：%+.2f 秒（%s）', value, direction), 3)
end
function M.menu()
    local function action(title, message, value)
        local command = {'script-message-to', mp.get_script_name(), message}
        if value then command[#command + 1] = value end
        return {title=title, value=command}
    end
    return {
        type='menu_global_danmaku_delay', title='弹幕整体偏移',
        footnote='作用于全部弹幕；各源处理完成后统一平移。换视频归零。',
        items={
            {title=string.format('当前整体偏移：%+.2f 秒', M.get()), selectable=false},
            action('全部弹幕提前 1 秒', 'danmaku-global-delay', '-1'),
            action('全部弹幕延后 1 秒', 'danmaku-global-delay', '1'),
            action('整体偏移归零', 'danmaku-global-delay-reset'),
        },
    }
end
function M.open_menu()
    local props = M.menu()
    if uosc_available then
        mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(props))
    elseif input_loaded and type(open_menu_select) == 'function' then
        open_menu_select(props.items)
    else show_message('没有可用的菜单框架', 3) end
end
local function refresh_menu()
    if uosc_available then
        mp.commandv('script-message-to', 'uosc', 'update-menu', utils.format_json(M.menu()))
    end
end
mp.register_script_message('danmaku-global-delay', function(value)
    report(M.adjust(tonumber(value)))
    refresh_menu()
end)
mp.register_script_message('danmaku-global-delay-reset', function()
    report(M.set(0))
    refresh_menu()
end)
mp.register_script_message('open_global_danmaku_delay_menu', M.open_menu)
-- File-loaded runs before new comments arrive. Comparing paths also handles
-- sources rebuilt in tests or by integrations without a file-loaded event.
mp.register_event('file-loaded', sync_path)
mp.set_property_native(property, 0)
return M
