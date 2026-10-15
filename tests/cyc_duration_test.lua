local path=debug.getinfo(1,"S").source:sub(2)
local root=path:match("^(.*)[/\\]tests[/\\]") or "."
package.path=root.."/?.lua;"..package.path
local utils=require("mp.utils")
local fails=0
local function check(name,ok) print((ok and "PASS " or "FAIL ")..name);if not ok then fails=fails+1 end end
local ok,w=pcall(require,"modules/cyc_web")
check("automatic CYC client available",ok)
if not ok then os.exit(1) end
local script='const DEFAULT_ACCOUNT = { username: "public-test", password: "test-only" }; throw new Error("must not execute")'
local account=w.parse_account(script)
check("account read without executing script",account and account.username=="public-test" and account.password=="test-only")
check("unrelated account ignored",not w.parse_account('const OTHER={username:"a",password:"b"}'))
check("executable password rejected",not w.parse_account('const DEFAULT_ACCOUNT={username:"a",password:getPassword()}'))
options={proxy=""};append_curl_timeout=function() end
local calls,queue={},{}
local logins,bootstraps,plays=0,0,0
local expired=false
call_cmd_async_with_timeout=function(args,_,cb)
 calls[#calls+1]=args
 local url=args[#args]
 local function arg(name) for i,v in ipairs(args) do if v==name then return args[i+1] end end end
 if url:find("update.greasyfork.org",1,true) then
  bootstraps=bootstraps+1;queue[#queue+1]=function() cb(nil,script) end
 elseif url:find("/auth/login",1,true) then
  logins=logins+1
  local body=utils.parse_json(arg('--data-raw') or '')
  check("login uses published account",body and body.username=="public-test" and body.password=="test-only")
  queue[#queue+1]=function() cb(nil,utils.format_json({code=0,data={token="test-token-"..logins,expires_at="2099-01-01T00:00:00Z"}})) end
 elseif url:find("/api/v2/sections/",1,true) then
  plays=plays+1
  if expired then expired=false;queue[#queue+1]=function() cb(nil,'{"code":401,"data":null}') end
  else queue[#queue+1]=function() cb(nil,'{"code":0,"data":{"url":"https://media.test/episode.mp4"}}') end end
 else error("Unexpected URL") end
 return function() end
end
local function drain() while #queue>0 do table.remove(queue,1)() end end
local results={}
w.play_url(52383,function(url,reason)results[1]={url,reason} end)
w.play_url(23053,function(url,reason)results[2]={url,reason} end)
drain()
check("no-config concurrent lookup succeeds",results[1][1]=="https://media.test/episode.mp4" and results[2][1]=="https://media.test/episode.mp4")
check("concurrent bootstrap and login deduplicated",bootstraps==1 and logins==1 and plays==2)
expired=true
w.play_url(52383,function(url,reason)results[3]={url,reason} end);drain()
check("expired session relogins once",results[3][1] and logins==2 and plays==4 and bootstraps==1)
local auth_redirect=false
for _,args in ipairs(calls) do
 if not args[#args]:find('update.greasyfork.org',1,true) then
  for _,v in ipairs(args) do if v=='-L' or v=='--location' then auth_redirect=true end end
 end
end
check("account requests never follow redirects",not auth_redirect)
package.loaded['modules/cyc_web']=nil;w=require('modules/cyc_web')
local failed_calls=0
call_cmd_async_with_timeout=function(_,_,cb)failed_calls=failed_calls+1;cb('offline',nil);return function()end end
local fail_reason
w.play_url(52383,function(url,reason)check('offline returns unknown',not url);fail_reason=reason end)
w.play_url(23053,function()end)
check("bootstrap failure backs off",failed_calls==1 and type(fail_reason)=="string")
package.loaded['modules/cyc_web']=nil;w=require('modules/cyc_web')
local denial_calls=0
call_cmd_async_with_timeout=function(args,_,cb)
 denial_calls=denial_calls+1
 if args[#args]:find('greasyfork',1,true) then cb(nil,script)
 elseif args[#args]:find('/auth/login',1,true) then cb(nil,'{"code":0,"data":{"token":"test-token"}}')
 else cb(nil,'{"code":401,"data":null}') end
 return function()end
end
w.play_url(52383,function(url,reason)check("persistent denial stays unknown",not url and type(reason)=="string") end)
check("persistent denial retry bounded",denial_calls==5)
if fails>0 then os.exit(1) end print('ALL PASS');os.exit(0)
