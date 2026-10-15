-- Read a bounded piece of media metadata, never the full video or comment timeline.
local M = {}
local LIMIT = 1048576
local function u32(s,i)
    local a,b,c,d=s:byte(i,i+3)
    if not d then return nil end
    return ((a*256+b)*256+c)*256+d
end
local function u64(s,i)
    local hi,lo=u32(s,i),u32(s,i+4)
    if not lo or hi>2097151 then return nil end
    return hi*4294967296+lo
end
function M.mp4(s)
    if type(s)~="string" then return nil end
    -- A head range can truncate a large moov after its complete mvhd.
    -- Trust that partial container only at a verified top-level box boundary.
    -- Tail ranges may start inside mdat, so scanned moov boxes must be complete.
    local function top_level(target)
        local pos=1
        while pos<target do
            local len=u32(s,pos)
            if len==1 then len=u64(s,pos+8) end
            if not len or len<8 then return false end
            pos=pos+len
        end
        return pos==target
    end
    local start=1
    while true do
        local at=s:find("moov",start,true)
        if not at then return nil end
        start=at+4
        local size=at>=5 and u32(s,at-4)
        local head=4
        if size==1 then size=u64(s,at+4);head=12 end
        if size and size>=head+4 and (at-4+size-1<=#s or top_level(at-4)) then
            local pos,last=at+head,math.min(at-4+size-1,#s)
            while pos+7<=last do
                local len,kind=u32(s,pos),s:sub(pos+4,pos+7)
                local header=8
                if len==1 then len=u64(s,pos+8);header=16 end
                if not len or len<header or pos+len-1>last then break end
                if kind=="mvhd" then
                    local p=pos+header
                    local ver=s:byte(p)
                    local timescale,duration
                    if ver==0 and len>=header+20 then
                        timescale,duration=u32(s,p+12),u32(s,p+16)
                        if duration==4294967295 then return nil end
                    elseif ver==1 and len>=header+32 then
                        timescale,duration=u32(s,p+20),u64(s,p+24)
                    end
                    if timescale and timescale>0 and duration and duration>0 then return duration/timescale end
                end
                pos=pos+len
            end
        end
    end
end
function M.hls(s)
    if type(s)~="string" or not s:match("^%s*#EXTM3U") or not s:find("#EXT%-X%-ENDLIST") then return nil end
    local total,count=0,0
    for line in s:gmatch("[^\r\n]+") do
        if line:match("^#EXTINF:") then
            local n=tonumber(line:match("^#EXTINF:([%d%.]+),"))
            if not n or n<=0 then return nil end
            total,count=total+n,count+1
        end
    end
    if count>0 then return total end
end
local function resolve(base,relative)
    if relative:match("^https?://") then return relative end
    local origin=base:match("^(https?://[^/]+)")
    if relative:sub(1,2)=="//" then return base:match("^(https?:)")..relative end
    if relative:sub(1,1)=="/" then return origin..relative end
    return base:match("^(.*[/])")..relative
end
function M.query(url,callback)
    if type(url)~="string" or not url:match("^https?://") then callback(nil,"播放地址无效");return end
    local function request(target,range,cb)
        local args={'curl','-L','-s','--fail','--ssl-no-revoke',
            '--proto','=http,https','--proto-redir','=http,https',
            '--max-redirs','3','--max-filesize',tostring(LIMIT),'--range',range}
        if options.cookie_file and options.cookie_file~='' then
            args[#args+1]='-b';args[#args+1]=mp.command_native({'expand-path',options.cookie_file})
        end
        if options.proxy and options.proxy~='' then args[#args+1]='-x';args[#args+1]=options.proxy end
        append_curl_timeout(args)
        args[#args+1]=target
        call_cmd_async_with_timeout(args,6,function(err,out)
            if err or type(out)~="string" or #out>LIMIT then cb(nil) else cb(out) end
        end)
    end
    local function probe(target,depth)
        request(target,'0-'..(LIMIT-1),function(out)
            if not out then callback(nil,"媒体元数据请求失败或超过读取上限");return end
            if out:match("^%s*#EXTM3U") then
                local n=M.hls(out)
                if n then callback(n);return end
                if depth<2 and out:find('#EXT%-X%-STREAM%-INF:') then
                    local next_uri=false
                    for line in out:gmatch("[^\r\n]+") do
                        if next_uri and line:sub(1,1)~='#' and line:match('%S') then
                            probe(resolve(target,line),depth+1);return
                        end
                        if line:match('^#EXT%-X%-STREAM%-INF:') then next_uri=true end
                    end
                end
                callback(nil,"播放清单未提供完整视频时长");return
            end
            local n=M.mp4(out)
            if n then callback(n);return end
            request(target,'-'..LIMIT,function(tail)
                local value=tail and M.mp4(tail)
                if value then callback(value) else callback(nil,"未能在有限媒体头尾中读取时长") end
            end)
        end)
    end
    probe(url,0)
end
return M
