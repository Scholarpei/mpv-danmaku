-- Matched video durations in seconds; never infer them from comment timestamps.
local utils = require("mp.utils")
local cache = require("modules/danmaku_cache")
local hash = require("modules/hash")
local M = {}
local providers, requests = {}, {}
local context_epoch, context_path, context_sources

function M.valid(value)
    local n = tonumber(value)
    if n and n > 0 and n < math.huge and n == n then return n end
end

function M.format(value)
    local n = M.valid(value)
    if not n then return "时长未知" end
    n = math.floor(n + 0.5)
    if n >= 3600 then return string.format("%d:%02d:%02d", math.floor(n/3600), math.floor(n/60)%60, n%60) end
    return string.format("%02d:%02d", math.floor(n/60), n%60)
end

function M.diff_text(source, current)
    source, current = M.valid(source), M.valid(current)
    if not source or not current then return "无法比较" end
    local diff = source - current
    local rounded = math.floor(math.abs(diff) + 0.5)
    if rounded == 0 then return "0秒" end
    return string.format("%s%d秒", diff > 0 and "+" or "-", rounded)
end

function M.summary(source, current, querying, info)
    if not M.valid(source) and info and M.valid(info.reference_seconds) then
        local text=M.format(info.reference_seconds)
        if M.valid(current) then text=text.."（"..M.diff_text(info.reference_seconds,current).."）" end
        return "参考 "..text
    end
    if not M.valid(source) then return querying and "时长查询中" or "时长未知" end
    local text = M.format(source)
    if M.valid(current) then text = text .. "（" .. M.diff_text(source,current) .. "）" end
    return "时长 " .. text
end

local function epoch()
    return type(source_status)=="table" and source_status.current_epoch() or nil
end
local function token(key)
    return type(source_status)=="table" and source_status.entry_token
        and source_status.entry_token(key) or nil
end
local function refresh()
    if type(refresh_source_stats_menu)=="function" then refresh_source_stats_menu() end
end
local function cache_key(key) return "duration:" .. hash(key) end

-- Capture before starting a request. Identity checks also cover delete + re-add at the same URL.
function M.capture(key)
    local sources = type(DANMAKU)=="table" and DANMAKU.sources or nil
    local src = sources and sources[key]
    local entry, ep, path = token(key), epoch(), mp.get_property("path")
    local function current()
        return type(DANMAKU)=="table" and DANMAKU.sources==sources
            and sources and sources[key]==src and token(key)==entry
            and (src~=nil or entry~=nil) and ep==epoch() and path==mp.get_property("path")
    end
    local function write(value, from_cache)
        value=M.valid(value)
        if not value or not current() then return false end
        local changed=src and src.duration_seconds~=value
        if src then src.duration_seconds=value end
        if not from_cache then
            cache.put(cache_key(key), utils.format_json({duration_seconds=value}), {type="json"})
        end
        if changed and type(update_source_duration_history)=="function" then
            update_source_duration_history(key,value)
        end
        if entry then source_status.note_duration(key,value) else refresh() end
        return true
    end
    return write, current
end

local remembered = {}
function M.remember(key, value)
    value=M.valid(value)
    if value then remembered[key]=value end
end

function M.register(pattern, fetch)
    providers[#providers+1]={pattern=pattern,fetch=fetch}
end
local function sync_context()
    local sources=type(DANMAKU)=="table" and DANMAKU.sources or nil
    local ep,path=epoch(),mp.get_property("path")
    if sources~=context_sources or ep~=context_epoch or path~=context_path then
        requests={};context_sources,context_epoch,context_path=sources,ep,path
    end
end
function M.pending(key)
    sync_context()
    local r=requests[key]
    return r and r.state=="pending" and r.current() or false
end

function M.info(key)
    sync_context()
    local r=requests[key]
    if r and r.current() and r.info then return r.info end
    local reason="此源尚未接入视频时长查询"
    if tostring(key):match("^ddp:") or tostring(key):match("/api/v2/comment/") then
        reason="聚合弹幕源，没有唯一对应的视频时长"
    end
    if tostring(key):match("cycani%.org/anime/") then
        reason="尚未取得对应播放媒体时长"
    elseif tostring(key):match("lanerc%.[%w]+/vod/") then
        reason="详情无时长；加密播放元数据尚未接入解析"
    elseif tostring(key):match("yfsp%.tv/play/") then
        reason="尚未取得对应网页播放时长"
    end
    return {reason=reason}
end

function M.query(entries,sources)
    sync_context()
    local rows,seen={},{}
    for _,e in ipairs(entries or {}) do rows[#rows+1]=e;seen[e.key]=true end
    for key,s in pairs(sources or {}) do
        if not seen[key] and type(s)=="table" then rows[#rows+1]={key=key} end
    end
    for _,e in ipairs(rows) do
        local key=e.key
        local s=sources and sources[key]
        local value=M.valid(s and s.duration_seconds) or M.valid(e.duration_seconds)
        local r=requests[key]
        if not value and (not r or not r.current()) then
            local write,current=M.capture(key)
            r={state="unknown",current=current};requests[key]=r
            local hit=cache.get(cache_key(key))
            local obj=hit and utils.parse_json(hit.payload)
            local saved=remembered[key] or (obj and M.valid(obj.duration_seconds))
            if saved then
                write(saved, not remembered[key]);r.state="done"
            else
                for _,p in ipairs(providers) do
                    if key:find(p.pattern) then
                        r.state="pending"
                        local completed=false
                        local function finish(n, info)
                            if completed then return end
                            completed=true
                            if not current() or requests[key]~=r then return end
                            r.state="done"
                            r.info=type(info)=="table" and info or {reason="接口未返回有效视频时长"}
                            n=M.valid(n)
                            local from_cache = not n
                            if not n then
                                local stale=cache.get_stale(cache_key(key))
                                local old=stale and utils.parse_json(stale.payload)
                                n=old and M.valid(old.duration_seconds)
                            end
                            if n then write(n, from_cache) else refresh() end
                        end
                        -- Keep the UI finite even when a legacy helper fails to call back.
                        local timer=mp.add_timeout(20,function() finish(nil,{reason="视频时长查询超时"}) end)
                        local ok=pcall(p.fetch,key,function(n,info) timer:kill();finish(n,info) end)
                        if not ok then timer:kill();finish(nil) end
                        break
                    end
                end
            end
        end
    end
end
return M
