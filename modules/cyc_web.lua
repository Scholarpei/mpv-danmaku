-- agefans Enhance (MIT), https://greasyfork.org/scripts/424023
-- Read only its published DEFAULT_ACCOUNT; never execute downloaded JavaScript.
local utils=require("mp.utils")
local M={}
local BASE="https://www.cycani.org"
local SCRIPT="https://update.greasyfork.org/scripts/424023/agefans%20Enhance.user.js"
local account,session,pending,failed_at,failed_reason
function M.parse_account(text)
    if type(text)~="string" then return nil end
    local raw=text:match("const%s+DEFAULT_ACCOUNT%s*=%s*(%b{})")
    if not raw then return nil end
    local function field(name)
        local literal=raw:match(name..'%s*:%s*("[^"\r\n]*")')
        local value=literal and utils.parse_json(literal)
        if type(value)=="string" and #value>0 and #value<=256 then return value end
    end
    local username,password=field("username"),field("password")
    if username and password then return {username=username,password=password} end
end
local function request(url,body,token,callback)
    local args={'curl','-s','--ssl-no-revoke','--compressed','--proto','=https',
        '--max-filesize','1048576','-H','x-app-name: cyc_web',
        '-H','x-app-version: cycweb','-H','x-time-zone: Asia/Hong_Kong'}
    if body then
        args[#args+1]='-H';args[#args+1]='content-type: application/json'
        args[#args+1]='--data-raw';args[#args+1]=utils.format_json(body)
    end
    if token then args[#args+1]='-H';args[#args+1]='Authorization: Bearer '..token end
    if options.proxy and options.proxy~='' then args[#args+1]='-x';args[#args+1]=options.proxy end
    append_curl_timeout(args)
    args[#args+1]=url
    call_cmd_async_with_timeout(args,6,function(err,out)
        -- Never propagate curl errors that could contain account/session data.
        callback(not err and type(out)=="string" and #out<=1048576 and out or nil)
    end)
end
local function ensure_session(callback)
    if session and os.time()-session.at<21600 then callback(session.token);return end
    if pending then pending[#pending+1]=callback;return end
    if failed_at and os.time()-failed_at<60 then callback(nil,failed_reason);return end
    pending={callback}
    local function finish(token,reason)
        if token then session={token=token,at=os.time()};failed_at=nil
        else session=nil;failed_at=os.time();failed_reason=reason end
        local waiting=pending;pending=nil
        for _,cb in ipairs(waiting) do cb(token,reason) end
    end
    local function login()
        request(BASE..'/api/auth/login',account,nil,function(raw)
            local obj=raw and utils.parse_json(raw)
            local data=type(obj)=="table" and obj.code==0 and obj.data
            local token=type(data)=="table" and data.token
            if type(token)~="string" or token=="" or token:find('[\r\n]') then
                account=nil;finish(nil,"次元城脚本共享会话自动登录失败");return
            end
            token=token:gsub('^[Bb]earer%s+','')
            finish(token)
        end)
    end
    if account then login();return end
    request(SCRIPT,nil,nil,function(raw)
        account=M.parse_account(raw)
        if not account then finish(nil,"次元城脚本公开账号配置获取失败");return end
        login()
    end)
end
function M.play_url(sid,callback)
    if not tostring(sid):match('^%d+$') then callback(nil,"分集标识无效");return end
    local function attempt(retried)
        ensure_session(function(token,reason)
            if not token then callback(nil,reason);return end
            request(BASE..'/api/v2/sections/'..sid..'/play-url',nil,token,function(raw)
                local obj=raw and utils.parse_json(raw)
                if type(obj)~="table" then callback(nil,"次元城播放地址请求失败");return end
                if tonumber(obj.code)==401 then
                    if session and session.token==token then session=nil end
                    if not retried then attempt(true);return end
                    failed_at=os.time();failed_reason="次元城脚本共享会话不可用"
                    callback(nil,failed_reason);return
                end
                local data=obj.code==0 and type(obj.data)=="table" and obj.data
                if not data or type(data.url)~="string" or not data.url:match('^https?://') then
                    callback(nil,tonumber(obj.code)==500 and "次元城播放地址解析失败" or "次元城播放接口未返回有效媒体地址");return
                end
                callback(data.url)
            end)
        end)
    end
    attempt(false)
end
return M
