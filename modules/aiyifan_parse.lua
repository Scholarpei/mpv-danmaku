-- 爱壹帆（yfsp.tv）App API 签名与搜索/选集/详情/弹幕的纯解析函数
-- （除 mp.utils 零 mp 依赖，单测直打；md5 照 modules/maiduidui_parse.lua 先例）
-- 调用方：apis/aiyifan_search.lua、sites/aiyifan.lua（网络与密钥引导状态机在后者）
--
-- 接口形态（2026-10-13 实测，见 tests/fixtures/ayf_*）：
--   Base https://api.tripdata.app/（接口域与站点 www.yfsp.tv 分离）；响应信封
--     {ret=200, data={…}, msg}，成功判据 ret===200；弹幕接口错误 videoId 与无弹幕
--     同口径（ret=200 且 list=[]），不可区分、均按合法空处理
--   签名（App com.ppde.ppcd v1.7.8 逆向，参考 danmu_api aiyifan-util.js）：
--     GET  x-sign = md5(按序拼接的 query 串 + 秒级时间戳 + 私钥)（参数序实测
--          GetBarrages=mediaKey&videoId&videoType、VideoDetails=mediaKey&videoType&episodeKey）
--     POST 签名 query 部分固定 "_t={时间戳}"（空参数 GET 同样回退 _t=<ts>）
--     头：x-timestamp（秒）、x-pub（公钥）、x-sign
--   密钥引导（⚠️ 运行时密钥不可硬编码，服务端可换）：
--     GET api/home/config?_t={ts}（用默认私钥签名、x-pub 置空串）→
--     data.list.pConfig {publicKey, privateKey[]}（privateKey 为数组取 [1]，实测 20 字符）
--   固定头（照 App okhttp 拦截器，见 sites/aiyifan.lua）：User-Agent okhttp-okgo/jeasonlzy、
--     BundleId com.cqcsy.ifvod、AppVersion 1.7.8、System Android、SystemVersion 17、
--     DeviceInfo Xiaomi 23127PN0CC、DeviceId 2da4a414036a4332782795a031dcab6b4、
--     Version V3、Lang 0、Lat/Lng 0.0
--   搜索 POST api/List/GetTitleGetData body {"SearchCriteria":kw} → data.list[]
--     {title, mediaKey, mediaId, mediaType(动漫/电影/电视剧/综艺), contentType(冒险/热血/…),
--      coverImgUrl, episodes[]}——⚠️ 内嵌 episodes 仅前 6 条预览且 uniqueID 恒空，
--      真选集必须走 VideoChooseGather
--   选集 POST api/Video/VideoChooseGather body {"mediaKey":id} → data.list[]
--     {episodeKey, uniqueID, episodeId, episodeTitle("01"), title(剧名), videoType}
--     （列表序=集数序，实测升序；⚠️ 弹幕 videoId 必须用 uniqueID——ep5 起与 episodeId
--      分叉（芙莉莲 ep5 uniqueID=914774/episodeId=914790），用 episodeId 实测返回空）
--   详情 GET api/Video/VideoDetails?mediaKey=&videoType=&episodeKey= → data.detailInfo
--     {uniqueID, episodeId, videoType}——站点原生链接 /play/{mediaKey}?id={episodeKey}
--     不带 videoId，经此补齐（uniqueID 优先、episodeId 兜底）
--   弹幕 GET api/Video/GetBarrages?mediaKey={id}&videoId={uniqueID}&videoType= → data.list[]
--     {second(秒，响应已按 second 升序、此处防御性再排), position, color("#RRGGBB" 大小写
--      混合), contxt(文本；content 为备选字段，实测恒空), good}；单次全量不分段（同埋堆堆）
--     position 语义（站点播放器自身枚举实锤 Barrel=0滚动/FixTop=1顶部/FixBottom=2底部）：
--     0→B站1滚动、1→5顶、2→4底（danmu_api 把 2 当滚动，此处按播放器枚举修正）

local md5 = require("modules/md5")

local M = {}

-- 引导请求的内置私钥（服务端可换运行时密钥，此钥仅用于 home/config 引导）
M.DEFAULT_PRIVATE_KEY = "57688*1-331@"

-- App 签名：md5(query .. x-timestamp .. 私钥)——GET 与 POST 同式，query 由 build_sign_query 构造
function M.app_sign(query, timestamp, private_key)
    return md5.sum(query .. tostring(timestamp) .. tostring(private_key))
end

-- 签名 query 构造：GET 用参数按序拼接 "k=v&"，POST/空参数回退 "_t=<ts>"。
-- params 为有序数组 {{k, v}, …}（顺序即签名串顺序，Lua 表 pairs 无序故不用 table）；
-- v 为 nil 的项跳过（照 danmu_api buildSignQuery 跳过 null 语义）
function M.build_sign_query(method, params, timestamp)
    if method == "POST" then return "_t=" .. tostring(timestamp) end
    if type(params) == "table" then
        local parts = {}
        for _, kv in ipairs(params) do
            if kv[2] ~= nil then parts[#parts + 1] = tostring(kv[1]) .. "=" .. tostring(kv[2]) end
        end
        if #parts > 0 then return table.concat(parts, "&") end
    end
    return "_t=" .. tostring(timestamp)
end

-- 失败响应的可读信息（msg 或 data.msg，日志用）
function M.parse_error_msg(d)
    if type(d) ~= "table" then return nil end
    if type(d.msg) == "string" and d.msg ~= "" then return d.msg end
    if type(d.data) == "table" and type(d.data.msg) == "string" then return d.data.msg end
    return nil
end

-- ============ 密钥引导（home/config 响应） ============

-- → { ok=bool, public_key, private_key }；privateKey 为数组取 [1]、字符串原样；
-- ret≠200 / pConfig 缺失 / 任一键为空均不 ok
function M.parse_config(d)
    local result = { ok = false, public_key = nil, private_key = nil }
    if type(d) ~= "table" or d.ret ~= 200 then return result end
    local list = type(d.data) == "table" and type(d.data.list) == "table" and d.data.list or nil
    local pc = list and type(list.pConfig) == "table" and list.pConfig or nil
    if not pc then return result end
    local pub = type(pc.publicKey) == "string" and pc.publicKey or nil
    local priv = pc.privateKey
    if type(priv) == "table" then priv = priv[1] end
    if not pub or type(priv) ~= "string" or priv == "" then return result end
    result.public_key = pub
    result.private_key = priv
    result.ok = true
    return result
end

-- ============ 搜索（GetTitleGetData 响应） ============

-- → { ok=bool, items={ {media_key, title, media_type, content_type} } }
-- mediaType/contentType 透传给菜单标注（动漫/电影/电视剧/综艺，不强制过滤）；
-- 无 mediaKey/mediaId 或无 title 的条目跳过
function M.parse_search(d)
    local result = { ok = false, items = {} }
    if type(d) ~= "table" or d.ret ~= 200 then return result end
    result.ok = true
    local list = type(d.data) == "table" and type(d.data.list) == "table" and d.data.list or {}
    for _, it in ipairs(list) do
        if type(it) == "table" and type(it.title) == "string" and it.title ~= "" then
            local mk = it.mediaKey or it.mediaId
            if mk then
                result.items[#result.items + 1] = {
                    media_key = tostring(mk),
                    title = it.title,
                    media_type = type(it.mediaType) == "string" and it.mediaType or "",
                    content_type = type(it.contentType) == "string" and it.contentType or "",
                }
            end
        end
    end
    return result
end

-- ============ 选集（VideoChooseGather 响应） ============

-- → { ok=bool, episodes={ {episode_key, video_id, title, video_type} } }
-- video_id 即弹幕入参 uniqueID（episodeId 兜底）；title 取 episodeTitle（备选 title）；
-- videoType 透传（正片 1 / 剧场版 0，实测弹幕接口对两者均收）；列表序=集数序
function M.parse_episodes(d)
    local result = { ok = false, episodes = {} }
    if type(d) ~= "table" or d.ret ~= 200 then return result end
    result.ok = true
    local list = type(d.data) == "table" and type(d.data.list) == "table" and d.data.list or {}
    for _, ep in ipairs(list) do
        if type(ep) == "table" and ep.episodeKey then
            local vid = ep.uniqueID or ep.episodeId
            if vid then
                local title = type(ep.episodeTitle) == "string" and ep.episodeTitle ~= ""
                    and ep.episodeTitle
                    or (type(ep.title) == "string" and ep.title or "")
                result.episodes[#result.episodes + 1] = {
                    episode_key = tostring(ep.episodeKey),
                    video_id = tostring(vid),
                    title = title,
                    video_type = tostring(ep.videoType or 1),
                }
            end
        end
    end
    return result
end

-- ============ 详情（VideoDetails 响应，老链接缺 videoId 补齐） ============

-- → { ok=bool, video_id, video_type }；uniqueID 优先、episodeId 兜底
function M.parse_details(d)
    local result = { ok = false, video_id = nil, video_type = nil }
    if type(d) ~= "table" or d.ret ~= 200 then return result end
    local di = type(d.data) == "table" and type(d.data.detailInfo) == "table" and d.data.detailInfo or nil
    if not di then return result end
    local vid = di.uniqueID or di.episodeId
    if not vid then return result end
    result.video_id = tostring(vid)
    result.video_type = tostring(di.videoType or 1)
    result.ok = true
    return result
end

-- ============ 弹幕（GetBarrages 响应） ============

-- "#RRGGBB" → 整数；无效返回 16777215（白）
local function hex_to_int(hex)
    if type(hex) ~= "string" then return 16777215 end
    local s = hex:gsub("^#", ""):gsub("%s+", "")
    if not s:match("^%x%x%x%x%x%x$") then return 16777215 end
    return tonumber(s, 16)
end

-- position（站点枚举 0滚动/1顶/2底）→ B站 mode 1滚动/5顶/4底；未知按滚动兜底
local function position_to_mode(position)
    if position == 1 then return 5 end
    if position == 2 then return 4 end
    return 1
end

-- → { ok=bool, comments={ {time=秒, color=整数RGB, mode=1/4/5, text} } }
-- ret=200 且 list=[] 为合法空（错误 videoId 同口径）；文本 contxt 优先 content 兜底；
-- second 非数或文本为空的畸形单条跳过不击穿整批；按 time 升序
function M.parse_danmaku(d)
    local out = { ok = false, comments = {} }
    if type(d) ~= "table" or d.ret ~= 200 then return out end
    out.ok = true
    local list = type(d.data) == "table" and type(d.data.list) == "table" and d.data.list or {}
    for _, c in ipairs(list) do
        if type(c) == "table" then
            local sec = tonumber(c.second)
            local text = type(c.contxt) == "string" and c.contxt ~= "" and c.contxt
                or (type(c.content) == "string" and c.content or nil)
            if sec and text then
                out.comments[#out.comments + 1] = {
                    time = sec,
                    color = hex_to_int(c.color),
                    mode = position_to_mode(tonumber(c.position)),
                    text = text,
                }
            end
        end
    end
    table.sort(out.comments, function(a, b) return a.time < b.time end)
    return out
end

return M
