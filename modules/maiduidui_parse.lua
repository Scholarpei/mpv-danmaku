-- 埋堆堆（TVB）签名与搜索/分集/弹幕的纯解析函数（无硬性 mp.* 依赖以便单元测试）
-- 调用方：apis/maiduidui_search.lua、sites/maiduidui.lua
--
-- 接口形态（2026-10 实测）：
--   全部 POST mob.mddcloud.com.cn，包裹体 {channel:"1000", data=<业务JSON>, deviceNum,
--     deviceType:0, jsonSign:0, os:"Android", sign, sourceVersion:0, terminalType:"APP",
--     thirdStatus:0, time:<ms>, version:"5.8.00", visitorStatus:0}；
--     sign = md5("os:Android|version:5.8.00|action:<路径>|time:<ms>|appToken:|privateKey:<私钥>|data:<未编码k=v&串>")
--     headers：UA "Mdd/5.8.00 (Android+32+)"、Content-Type json、version: 5.8.00
--   搜索 data={"keyWord":kw} → data[] 为分组[{vodList[], type, isExact}]；
--     条目 {uuid, name("法证先锋(粤)"), materialName("警匪"), totalNum, coverImage}——无年份字段
--   分集 data={"hasIntroduction":0, vodUuid} → data[] = {uuid, name("法证先锋(粤)01"), duration(秒字符串)}
--   弹幕 data={"sactionUuid", times:0, vodUuid} → data[] = [{times(秒字符串), barrageList[]}];
--     条目 {color("#ffffff"), content, times(秒字符串)}；一次请求返回全集（实测无需分段）

local md5 = require("modules/md5")

local M = {}

local PRIVATE_KEY = "e1be6b4cf4021b3d181170d1879a530a9e4130b69032144d5568abfd6cd6c1c2"
local VERSION = "5.8.00"
local DEVICE_NUM = "853BDD7A1DC011F1C341455071C03AEB"

-- 业务 data 表 → 未编码 "k=v&" 串（固定键序：table.concat 需调用方保证有序小表）
function M.raw_data_string(data)
    local parts = {}
    for k, v in pairs(data) do
        parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
    end
    table.sort(parts)
    return table.concat(parts, "&") .. "&"
end

-- 签名（确定性纯函数：time_ms 由调用方传入）
function M.sign(path, data, time_ms)
    local src = ("os:Android|version:%s|action:%s|time:%d|appToken:|privateKey:%s|data:%s")
        :format(VERSION, path, time_ms, PRIVATE_KEY, M.raw_data_string(data))
    return md5.sum(src)
end

-- 完整请求包裹体
function M.wrap_body(data, time_ms, sign)
    return {
        channel = "1000",
        data = data,
        deviceNum = DEVICE_NUM,
        deviceType = 0,
        jsonSign = 0,
        os = "Android",
        sign = sign,
        sourceVersion = 0,
        terminalType = "APP",
        thirdStatus = 0,
        time = time_ms,
        version = VERSION,
        visitorStatus = 0,
    }
end

-- "#RRGGBB" → 整数；无效返回 16777215
local function hex_to_int(hex)
    if type(hex) ~= "string" then return 16777215 end
    local s = hex:gsub("^#", ""):gsub("%s+", "")
    if not s:match("^%x%x%x%x%x%x$") then return 16777215 end
    return tonumber(s, 16)
end

-- 搜索响应 → { ok=bool, items={ {vod_uuid,name,material_name,total} } }
-- 响应 status 为 true 时 data 是分组数组；同一剧的粤语/国语多版本分列（name 带 (粤) 后缀）
function M.parse_search(d)
    local result = { ok = true, items = {} }
    if type(d) ~= "table" then
        return { ok = false, items = {} }
    end
    if d.status ~= true then
        return { ok = false, items = {} }
    end
    if type(d.data) ~= "table" then return result end

    local seen = {}
    for _, group in ipairs(d.data) do
        local vods = type(group) == "table" and type(group.vodList) == "table" and group.vodList or {}
        for _, it in ipairs(vods) do
            if type(it) == "table" and it.uuid and it.name then
                local uid = tostring(it.uuid)
                if not seen[uid] then
                    seen[uid] = true
                    table.insert(result.items, {
                        vod_uuid = uid,
                        name = tostring(it.name),
                        material_name = type(it.materialName) == "string" and it.materialName or "剧集",
                        total = tonumber(it.totalNum) or 0,
                    })
                end
            end
        end
    end
    return result
end

-- 分集响应 → { ok=bool, episodes={ {uuid,name} } }
function M.parse_sactions(d)
    local result = { ok = true, episodes = {} }
    if type(d) ~= "table" or d.status ~= true then
        return { ok = false, episodes = {} }
    end
    if type(d.data) ~= "table" then return result end
    for _, it in ipairs(d.data) do
        if type(it) == "table" and it.uuid then
            table.insert(result.episodes, {
                uuid = tostring(it.uuid),
                name = type(it.name) == "string" and it.name or "",
            })
        end
    end
    return result
end

-- 弹幕响应 → { time=秒, color=整数, mode=1, text=字符串 } 列表（sites 加载器用）
-- data[] 各时间块的 barrageList 拼接；times 均为秒字符串
function M.parse_barrage(d)
    local out = {}
    if type(d) ~= "table" or d.status ~= true then return out end
    if type(d.data) ~= "table" then return out end
    for _, seg in ipairs(d.data) do
        local list = type(seg) == "table" and type(seg.barrageList) == "table" and seg.barrageList or {}
        for _, c in ipairs(list) do
            if type(c) == "table" and type(c.content) == "string" then
                out[#out + 1] = {
                    time = tonumber(c.times) or 0,
                    color = hex_to_int(c.color),
                    mode = 1,
                    text = c.content,
                }
            end
        end
    end
    return out
end

return M
