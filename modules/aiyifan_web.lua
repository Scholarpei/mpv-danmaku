-- Public website metadata uses a different signature from the App comment API.
local utils = require("mp.utils")
local md5 = require("modules/md5")
local duration = require("modules/source_duration")
local M = {}
local config
local function encode(s)
    return tostring(s):gsub("([^%w%-_%.~])",function(c) return string.format("%%%02X",c:byte()) end)
end
function M.parse_config(html)
    if type(html)~="string" then return nil end
    local raw=html:match('"pConfig"%s*:%s*(%b{})')
    local obj=raw and utils.parse_json(raw)
    if type(obj)~="table" then return nil end
    local priv=type(obj.privateKey)=="table" and obj.privateKey[1] or obj.privateKey
    if type(obj.publicKey)=="string" and obj.publicKey~="" and type(priv)=="string" and priv~="" then
        return {pub=obj.publicKey,priv=priv}
    end
end
function M.signed_url(base,params,cfg)
    local query,decoded={},{}
    for _,kv in ipairs(params) do
        if kv[2]~=nil then
            query[#query+1]=encode(kv[1]).."="..encode(kv[2])
            decoded[#decoded+1]=kv[1].."="..tostring(kv[2])
        end
    end
    local sign=md5.sum(cfg.pub.."&"..table.concat(decoded,"&"):lower().."&"..cfg.priv)
    return base.."?"..table.concat(query,"&").."&vv="..sign.."&pub="..encode(cfg.pub)
end
local function get(url,callback)
    local args={'curl','-L','-s','--ssl-no-revoke','--compressed',
        '--user-agent','Mozilla/5.0','--referer','https://www.yfsp.tv/'}
    if options.cookie_file and options.cookie_file~='' then
        args[#args+1]='-b';args[#args+1]=mp.command_native({'expand-path',options.cookie_file})
    end
    if options.proxy and options.proxy~='' then args[#args+1]='-x';args[#args+1]=options.proxy end
    append_curl_timeout(args)
    args[#args+1]=url
    return call_cmd_async_with_timeout(args,8,callback)
end
function M.query(ids,callback)
    if not ids.episode_key then callback(nil,{reason="链接缺少分集标识，无法核对时长"});return end
    local function request(cfg,retried)
        local url=M.signed_url("https://m10.yfsp.tv/v3/video/play",{
            {"cinema",1},{"id",ids.episode_key},{"lang","cns"},{"usersign",1},
            {"region","GL."},{"device",1},{"a",0},{"isMasterSupport",1},{"v",1},
        },cfg)
        get(url,function(err,out)
            local obj=not err and type(out)=="string" and utils.parse_json(out)
            local data=type(obj)=="table" and obj.data
            if obj and obj.ret==200 and type(data)=="table" and data.code~=0 and not retried then
                config=nil
                get("https://www.yfsp.tv/play/"..ids.media_key,function(e,html)
                    local fresh=not e and M.parse_config(html)
                    if not fresh then callback(nil,{reason="网页签名更新失败"});return end
                    config={value=fresh,at=os.time()};request(fresh,true)
                end)
                return
            end
            local media=type(data)=="table" and data.code==0 and type(data.info)=="table" and data.info[1]
            if type(media)~="table" or obj.ret~=200 then callback(nil,{reason="网页播放信息请求失败"});return end
            if media.needLogin and media.needLogin~=0 and media.needLogin~=false then
                callback(nil,{reason="本次播放接口要求登录"});return
            end
            if media.isPreView or media.isLimitedStream then callback(nil,{reason="接口仅返回预览或受限播放信息"});return end
            local video_id=tostring(media.uniqueKey or ""):match("_(%d+)$")
            if media.key~=ids.media_key or media.mediaKey~=ids.episode_key
                or (ids.video_id and video_id~=tostring(ids.video_id)) then
                callback(nil,{reason="播放信息与已匹配分集不一致"});return
            end
            -- customData.t is the player's total length; flvPathList includes ads.
            local n=type(media.customData)=="table" and duration.valid(media.customData.t)
            callback(n,{reason=n and nil or "播放接口未提供正片总时长"})
        end)
    end
    if config and os.time()-config.at<1800 then request(config.value,false);return end
    get("https://www.yfsp.tv/play/"..ids.media_key,function(err,html)
        local cfg=not err and M.parse_config(html)
        if not cfg then callback(nil,{reason="网页签名配置获取失败"});return end
        config={value=cfg,at=os.time()};request(cfg,false)
    end)
end
return M
