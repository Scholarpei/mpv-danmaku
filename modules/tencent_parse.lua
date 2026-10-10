-- 腾讯搜索/剧集列表/弹幕条目的纯解析函数（照 bilibili_match.lua 无硬性 mp.* 依赖以便单元测试）
-- 调用方：apis/tencent_search.lua（搜索与剧集流程）、sites/tencentvideo.lua（弹幕条目）
--
-- 接口形态复刻自 danmaku-anywhere 的 tencent provider（packages/danmaku-provider/src/providers/tencent/schema.ts）：
--   MbSearch 项 = { doc={id,...}, videoInfo={videoType,typeName,title,year,episodeSites} }，
--   过滤 year==0 与 episodeSites 为空的项；剧集项 = item_params={vid,is_trailer,play_title,title,union_title}；
--   弹幕 content_style 为字符串化 JSON（腾讯返回的不是嵌套对象），颜色 gradient_colors[1] 优先于 color

-- mp.utils 仅供 content_style 字符串解码使用；脱离 mpv 独立运行时缺失则退化为白色
local has_mp_utils, mp_utils = pcall(require, "mp.utils")

local M = {}

-- 去除搜索结果标题里的 <em class="highlight"> 等高亮标签并修剪空白
local function strip_html(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("<[^>]->", "")
    s = s:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&quot;", '"')
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- "#RRGGBB"/"RRGGBB"/"RGB"/数字 → 整数颜色；无法解析返回 nil
local function hex_to_int(hex)
    if type(hex) == "number" then return math.floor(hex) end
    if type(hex) ~= "string" then return nil end
    local s = hex:gsub("^#", ""):gsub("%s+", ""):lower()
    if #s == 3 then
        s = s:sub(1, 1) .. s:sub(1, 1) .. s:sub(2, 2) .. s:sub(2, 2) .. s:sub(3, 3) .. s:sub(3, 3)
    end
    if not s:match("^%x%x%x%x%x%x$") then return nil end
    return tonumber(s, 16)
end

-- content_style（字符串化 JSON 或已解码 table）→ 颜色整数值；无有效样式返回 nil
-- 渐变色无法呈现，取 gradient_colors 首色（与 danmaku-anywhere 行为一致）
local function style_to_color(style)
    if type(style) == "string" and has_mp_utils then
        style = mp_utils.parse_json(style)
    end
    if type(style) ~= "table" then return nil end
    local grad = style.gradient_colors
    if type(grad) == "table" then
        local first = grad[1] or grad["0"]
        if first ~= nil then
            local c = hex_to_int(first)
            if c then return c end
        end
    end
    if style.color ~= nil then
        return hex_to_int(style.color)
    end
    return nil
end

-- MbSearch 响应（已 parse_json 的 table）→ { ok=bool, msg=string?, items={ {cid,title,year,type_name,video_type} } }
-- 结果区优先取 areaBoxList 中 boxId=="MainNeed" 的 itemList，否则回退 normalList.itemList；
-- 过滤 year==0（未收录年份）与 episodeSites 为空的项；按 cid 去重
function M.parse_mb_search(d)
    local result = { ok = true, items = {} }
    if type(d) ~= "table" then
        return { ok = false, items = {} }
    end
    local ret = tonumber(d.ret)
    if ret ~= nil and ret ~= 0 then
        return { ok = false, msg = tostring(d.msg or ""), items = {} }
    end

    local data = d.data
    if type(data) ~= "table" then return result end

    local raw_list = nil
    if type(data.areaBoxList) == "table" then
        for _, box in ipairs(data.areaBoxList) do
            if type(box) == "table" and box.boxId == "MainNeed"
                and type(box.itemList) == "table" then
                raw_list = box.itemList
                break
            end
        end
    end
    if not raw_list and type(data.normalList) == "table"
        and type(data.normalList.itemList) == "table" then
        raw_list = data.normalList.itemList
    end

    local seen = {}
    for _, item in ipairs(raw_list or {}) do
        if type(item) == "table" and type(item.doc) == "table"
            and type(item.videoInfo) == "table" and item.doc.id then
            local vi = item.videoInfo
            local year = tonumber(vi.year) or 0
            local eps = type(vi.episodeSites) == "table" and vi.episodeSites or {}
            local cid = tostring(item.doc.id)
            if year ~= 0 and #eps > 0 and not seen[cid] then
                seen[cid] = true
                table.insert(result.items, {
                    cid = cid,
                    title = strip_html(vi.title),
                    year = year,
                    type_name = type(vi.typeName) == "string" and vi.typeName or "",
                    video_type = tonumber(vi.videoType),
                })
            end
        end
    end
    return result
end

-- GetPageData 单页响应 → { ok=bool, msg=string?, episodes={ {vid,title} }, raw_count=number, has_next_page=bool }
-- 解析路径 data.module_list_datas[1].module_datas[1].item_data_lists.item_datas[].item_params；
-- is_trailer=="1" 的项过滤掉（集数编号 = 过滤后索引，菜单/续载/历史三处必须统一）；
-- 标题回退链 play_title → title → union_title；raw_count 为过滤前条数（has_next_page 缺失时的翻页判停依据）
function M.parse_episode_page(d)
    local result = { ok = true, episodes = {}, raw_count = 0, has_next_page = false }
    if type(d) ~= "table" then
        return { ok = false, episodes = {}, raw_count = 0, has_next_page = false }
    end
    local ret = tonumber(d.ret)
    if ret ~= nil and ret ~= 0 then
        return { ok = false, msg = tostring(d.msg or ""), episodes = {}, raw_count = 0, has_next_page = false }
    end

    local data = d.data
    if type(data) ~= "table" then return result end
    result.has_next_page = data.has_next_page == true

    local mld = data.module_list_datas
    if type(mld) ~= "table" or type(mld[1]) ~= "table" then return result end
    local md = mld[1].module_datas
    if type(md) ~= "table" or type(md[1]) ~= "table" then return result end
    local idl = md[1].item_data_lists
    local items = type(idl) == "table" and idl.item_datas or nil
    if type(items) ~= "table" then return result end

    for _, it in ipairs(items) do
        result.raw_count = result.raw_count + 1
        local p = type(it) == "table" and it.item_params or nil
        if type(p) == "table" and p.vid ~= nil and p.vid ~= ""
            and tostring(p.is_trailer) ~= "1" then
            local title = ""
            for _, key in ipairs({ "play_title", "title", "union_title" }) do
                if type(p[key]) == "string" and p[key] ~= "" then
                    title = strip_html(p[key])
                    break
                end
            end
            table.insert(result.episodes, { vid = tostring(p.vid), title = title })
        end
    end
    return result
end

-- 单条弹幕 → { time=秒, color=整数, mode=1, text=字符串 }；item 非 table 返回 nil
-- time_offset 毫秒转秒；颜色取 content_style（字符串化 JSON）的 gradient_colors 首色，无则 color，无则白色
function M.parse_barrage_item(item)
    if type(item) ~= "table" then return nil end
    local time = tonumber(item.time_offset)
    time = time and time / 1000 or 0
    local color = style_to_color(item.content_style) or 16777215
    local text = type(item.content) == "string" and item.content or ""
    return { time = time, color = color, mode = 1, text = text }
end

return M
