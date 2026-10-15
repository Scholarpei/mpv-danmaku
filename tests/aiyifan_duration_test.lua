local path=debug.getinfo(1,"S").source:sub(2)
local root=path:match("^(.*)[/\\]tests[/\\]") or "."
package.path=root.."/?.lua;"..package.path
local utils=require("mp.utils")
local fails=0
local function check(name,ok) print((ok and "PASS " or "FAIL ")..name);if not ok then fails=fails+1 end end
local ok,w=pcall(require,"modules/aiyifan_web")
check("web metadata client available",ok)
if not ok then os.exit(1) end
local html='<script>window.apiCache={"site-config":[{"pConfig":{"publicKey":"public","privateKey":["secret"]}}]};</script>'
local cfg=w.parse_config(html)
check("public page config parsed without executing JS",cfg and cfg.pub=="public" and cfg.priv=="secret")
check("missing page key rejected",not w.parse_config('<html></html>'))
check("signature follows lowercase decoded web query",w.signed_url("https://m10.yfsp.tv/v3/video/play",{{"id","AbC"},{"v",1}},cfg)=="https://m10.yfsp.tv/v3/video/play?id=AbC&v=1&vv=b3f5477746e878e1c7ee87ce4d3136bb&pub=public")
options={proxy=""};append_curl_timeout=function() end
local calls={}
local response={ret=200,data={code=0,info={{key="show",mediaKey="episode3",uniqueKey="22059_490603",customData={t=1451},needLogin=0,flvPathList={{duration=20,link="https://ad.test"}}}}}}
call_cmd_async_with_timeout=function(args,_,cb)
 calls[#calls+1]=args[#args]
 if #calls==1 then cb(nil,html) else cb(nil,utils.format_json(response)) end
 return function() end
end
local n,info
w.query({media_key="show",episode_key="episode3",video_id="490603"},function(a,b)n,info=a,b end)
check("matched playback total excludes 20 second ad",n==1451)
check("uses public web signed play route",calls[2] and calls[2]:find("/v3/video/play?",1,true) and calls[2]:find("vv=",1,true))
response.data.info[1].mediaKey="wrong"
w.query({media_key="show",episode_key="episode3",video_id="490603"},function(a,b)n,info=a,b end)
check("wrong episode does not supply duration",n==nil)
response.data.info[1].mediaKey="episode3";response.data.info[1].uniqueKey="22059_999"
w.query({media_key="show",episode_key="episode3",video_id="490603"},function(a,b)n,info=a,b end)
check("wrong video ID rejected",n==nil)
response.data.info[1].uniqueKey="22059_490603";response.data.info[1].isPreView=true
w.query({media_key="show",episode_key="episode3",video_id="490603"},function(a,b)n,info=a,b end)
check("preview not treated as full episode",n==nil)
response.data.info[1].isPreView=false;response.data.info[1].needLogin=1
w.query({media_key="show",episode_key="episode3",video_id="490603"},function(a,b)n,info=a,b end)
check("actual login denial reported from response",n==nil and info.reason:find("登录",1,true))
response.data.info[1].needLogin=0
w.query({media_key="show",video_id="490603"},function(a,b)n,info=a,b end)
check("missing episode key not guessed",n==nil)
response.data.info[1]={key="kIR43Z1lBD6",mediaKey="HyjriN5q810",uniqueKey="47157_1440641",customData={t=1447},needLogin=0}
w.query({media_key="kIR43Z1lBD6",episode_key="HyjriN5q810",video_id="1440641"},function(a,b)n,info=a,b end)
check("user example returns 24:07",n==1447)
response.data.info[1].customData={t=0};response.data.info[1].flvPathList={{duration=20,link="https://ad.test"}}
w.query({media_key="kIR43Z1lBD6",episode_key="HyjriN5q810",video_id="1440641"},function(a,b)n,info=a,b end)
check("missing total never replaced by ad length",n==nil)
local refresh_calls=0
call_cmd_async_with_timeout=function(args,_,cb)
 refresh_calls=refresh_calls+1
 if refresh_calls==1 then cb(nil,'{"ret":200,"data":{"code":1,"msg":"用户签名错误"}}')
 elseif refresh_calls==2 then cb(nil,html)
 else response.data.info[1].customData.t=1447;cb(nil,utils.format_json(response)) end
 return function() end
end
w.query({media_key="kIR43Z1lBD6",episode_key="HyjriN5q810",video_id="1440641"},function(a,b)n,info=a,b end)
check("rotated public signing config refreshed once",n==1447 and refresh_calls==3)
call_cmd_async_with_timeout=function(_,_,cb)cb(nil,'{"ret":200,"data":{"code":0,"info":[4]}}');return function()end end
w.query({media_key="show",episode_key="episode"},function(a,b)n,info=a,b end)
check("malformed media metadata returns unknown",n==nil)
if fails>0 then os.exit(1) end print("ALL PASS");os.exit(0)
