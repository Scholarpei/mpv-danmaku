-- 爱奇艺搜索与分集的纯解析函数（无硬性 mp.* 依赖以便单元测试）
-- 调用方：apis/iqiyi_search.lua
--
-- 接口形态（2026-10 实测）：
--   搜索 mesh.if.iqiyi.com/portal/lw/search/homePageV3（无签名，Origin/Referer iqiyi.com）→
--     data.templates[]：template 101 的 albumInfo = {title, subtitle("2023"), channel("电视剧,2"),
--     siteId("iqiyi"), pageUrl(https://www.iqiyi.com/v_<link_id>.html), totalNumber,
--     videos = [{title("狂飙第1集"), number("1"), pageUrl(每集规范播放页)}]}；
--     125 为推荐组、108 为相关内容 → 均跳过；站外源（siteId≠iqiyi）与原创/短剧频道过滤
--   分集：albumInfo.videos 即完整分集列表（航海王 1180 集实测无截断），number 非数字的
--     采访/花絮条目剔除，按 number 升序即集数编号
--   注：www.iqiyi.com 的 base_info 分集接口对 Schannel 系 TLS 指纹返回伪 "invalid sign"
--     （python OpenSSL 栈可过），故弃用、全部数据取自搜索响应

local M = {}

-- 频道白名单（channel 形如 "电视剧,2"）：过滤原创解说/短剧等干扰条目
local CHANNEL_WHITELIST = {
    ["电视剧"] = true,
    ["电影"] = true,
    ["综艺"] = true,
    ["动漫"] = true,
    ["纪录片"] = true,
}

-- 从 pageUrl 提取 link_id（https://www.iqiyi.com/v_<link_id>.html）
function M.link_id_from_url(url)
    if type(url) ~= "string" then return nil end
    return url:match("/v_([%w]+)%.html")
end

-- albumInfo.videos → 分集列表（number 非数字的采访/花絮剔除，按数字升序）
local function extract_episodes(album_info)
    local episodes = {}
    for _, v in ipairs(type(album_info.videos) == "table" and album_info.videos or {}) do
        if type(v) == "table" then
            local num = tonumber(v.number)
            local link_id = M.link_id_from_url(v.pageUrl)
            if num and link_id then
                episodes[#episodes + 1] = {
                    link_id = link_id,
                    number = num,
                    title = type(v.title) == "string" and v.title or "",
                }
            end
        end
    end
    table.sort(episodes, function(x, y) return x.number < y.number end)
    return episodes
end

-- 搜索响应 → { ok=bool, items={ {link_id,title,year,type_name,total,episodes={ {link_id,number,title} }} } }
-- 保留 template 101 且 siteId=="iqiyi"、频道白名单内的条目；link_id 去重；
-- 每条自带完整分集列表（episodes，菜单选集直接使用）
function M.parse_search(d)
    local result = { ok = true, items = {} }
    if type(d) ~= "table" then
        return { ok = false, items = {} }
    end
    local data = d.data
    if type(data) ~= "table" or type(data.templates) ~= "table" then return result end

    local seen = {}
    for _, tpl in ipairs(data.templates) do
        if type(tpl) == "table" and tpl.template == 101 then
            local a = type(tpl.albumInfo) == "table" and tpl.albumInfo or nil
            if a and a.siteId == "iqiyi" and type(a.title) == "string" then
                local channel = type(a.channel) == "string" and (a.channel:match("^([^,]+)")) or nil
                local link_id = M.link_id_from_url(a.pageUrl)
                if channel and CHANNEL_WHITELIST[channel] and link_id and not seen[link_id] then
                    seen[link_id] = true
                    local episodes = extract_episodes(a)
                    result.items[#result.items + 1] = {
                        link_id = link_id,
                        title = a.title,
                        year = tonumber(a.subtitle) or 0,
                        type_name = channel,
                        total = tonumber(a.totalNumber) or #episodes,
                        episodes = episodes,
                    }
                end
            end
        end
    end
    return result
end

return M
