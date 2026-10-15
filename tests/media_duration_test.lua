local path=debug.getinfo(1,"S").source:sub(2)
package.path=(path:match("^(.*)[/\\]tests[/\\]") or ".").."/?.lua;"..package.path
local failures=0
local function check(name,ok) print((ok and "PASS " or "FAIL ")..name);if not ok then failures=failures+1 end end
local ok,p=pcall(require,"modules/media_duration")
check("media metadata probe available",ok)
if not ok then os.exit(1) end
local function be(n) return string.char(math.floor(n/16777216)%256,math.floor(n/65536)%256,math.floor(n/256)%256,n%256) end
local function box(t,s) return be(#s+8)..t..s end
local mvhd=box("mvhd",string.rep("\0",12)..be(1000)..be(1471650)..string.rep("\0",80))
check("MP4 movie header seconds",p.mp4(box("ftyp","isom")..box("moov",mvhd))==1471.65)
check("tail range starts inside mdat",p.mp4("random mdat bytes"..box("moov",mvhd))==1471.65)
local v1=box("mvhd",string.char(1)..string.rep("\0",19)..be(1000)..be(0)..be(1471650)..string.rep("\0",80))
check("MP4 version 1 header",p.mp4(box("moov",v1))==1471.65)
check("partial moov rejected",p.mp4(box("moov",mvhd):sub(1,-5))==nil)
check("bare mvhd rejected",p.mp4(mvhd)==nil)
-- Real CYC header: moov is 1069822 bytes, but its complete mvhd is in the first 144.
local cyc_head=("0000001c6674797069736f6d0000020069736f6d69736f326d703431001052fe6d6f6f760000006c6d766864000000000000000000000000000003e80017801a0001000001000000000000000000000000010000000000000000000000000000000100000000000000000000000000004000000000000000000000000000000000000000000000000000000000000003"):gsub("..",function(h) return string.char(tonumber(h,16)) end)
check("CYC large moov reads complete movie header",p.mp4(cyc_head)==1540.122)
check("CYC incomplete movie header rejected",p.mp4(cyc_head:sub(1,-2))==nil)
check("embedded partial moov in media bytes rejected",p.mp4(box("mdat",cyc_head))==nil)
check("HLS completed playlist duration",p.hls("#EXTM3U\n#EXTINF:6.25,\na.ts\n#EXTINF:5.5,\nb.ts\n#EXT-X-ENDLIST\n")==11.75)
check("live HLS not a total duration",p.hls("#EXTM3U\n#EXTINF:6,\na.ts\n")==nil)
check("invalid HLS rejected",p.hls("#EXTM3U\n#EXTINF:bad,\na.ts\n#EXT-X-ENDLIST")==nil)
local calls,reply,reply_reason={},nil,nil
options={proxy=""};append_curl_timeout=function() end
call_cmd_async_with_timeout=function(args,timeout,cb)
 calls[#calls+1]=args
 local body=#calls==1 and box("ftyp","isom") or "mdat tail"..box("moov",mvhd)
 cb(nil,body)
end
p.query("https://media.test/3.mp4",function(n,reason) reply,reply_reason=n,reason end)
check("MP4 tail lookup yields duration",reply==1471.65 and #calls==2)
check("successful tail lookup clears unknown reason",reply_reason==nil)
local joined=table.concat(calls[1]," ")
check("media probe bounded and protocol restricted",joined:find("--max-filesize 1048576",1,true) and joined:find("--proto =http,https",1,true) and joined:find("--range 0-1048575",1,true))
calls={};reply=nil
call_cmd_async_with_timeout=function(args,_,cb)
 calls[#calls+1]=args
 if #calls==1 then cb(nil,"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nlow/index.m3u8\n")
 else cb(nil,"#EXTM3U\n#EXTINF:12,\na.ts\n#EXT-X-ENDLIST\n") end
end
p.query("https://media.test/show/master.m3u8",function(n) reply=n end)
check("HLS master follows corresponding child",reply==12 and calls[2][#calls[2]]=="https://media.test/show/low/index.m3u8")
local calls_before=#calls
p.query("file:///private.mp4",function(n) reply=n end)
check("non HTTP media rejected",reply==nil and #calls==calls_before)
call_cmd_async_with_timeout=function(_,_,cb) cb(nil,string.rep("x",1048577)) end
p.query("https://media.test/ignored-range.mp4",function(n) reply=n end)
check("oversize response never parsed",reply==nil)
call_cmd_async_with_timeout=function(_,_,cb) cb("offline",nil) end
p.query("https://media.test/offline.mp4",function(n) reply=n end)
check("network failure returns unknown",reply==nil)
if failures>0 then os.exit(1) end print("ALL PASS");os.exit(0)
