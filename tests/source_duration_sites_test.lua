local path=debug.getinfo(1,"S").source:sub(2)
local dir=path:match("^(.*)[/\\]") or "."
local root=dir:match("^(.*)[/\\]") or "."
package.path=root.."/?.lua;"..package.path
local utils=require("mp.utils")
local d=require("modules/source_duration")
local failures=0
local function check(name,ok) print((ok and "PASS " or "FAIL ")..name);if not ok then failures=failures+1 end end
show_message=function() end
source_status=require("modules/source_status")
DANMAKU={sources={}}
require("modules/options");require("modules/utils")
for _,name in ipairs({"bilibili","iqiyi","youku","mgtv","acfun","ggl","animeko","aiyifan","cyc"}) do require("sites/"..name) end
require("apis/maiduidui_search")
require("apis/bilibili_search")
local function fixture(name) local f=assert(io.open(root.."/tests/fixtures/"..name,"rb"));local s=f:read("*all");f:close();return s end
local calls=0
local recorded_calls={}
local function be(n) return string.char(math.floor(n/16777216)%256,math.floor(n/65536)%256,math.floor(n/256)%256,n%256) end
local function box(t,s) return be(#s+8)..t..s end
local responses={
 {"update.greasyfork.org/scripts/424023/",'const DEFAULT_ACCOUNT={username:"public-test",password:"test-only"};'},
 {"/api/auth/login",'{"code":0,"data":{"token":"test-token","expires_at":"2099-01-01T00:00:00Z"}}'},
 {"/api/home/config?",'{"ret":200,"data":{"list":{"pConfig":{"publicKey":"app-pub","privateKey":["app-secret"]}}}}'},
 {"/api/Video/VideoChooseGather?",'{"ret":200,"data":{"list":[{"episodeKey":"fbrlqA5zaV9","uniqueID":490603,"episodeTitle":"01","videoType":1}]}}'},
 {"www.yfsp.tv/play/",'<script>window.apiCache={"site-config":[{"pConfig":{"publicKey":"public","privateKey":["secret"]}}]};</script>'},
 {"/v3/video/play?",'{"ret":200,"data":{"code":0,"info":[{"key":"3pTkJk5j9f6","mediaKey":"fbrlqA5zaV9","uniqueKey":"22059_490603","customData":{"t":1451},"needLogin":0}]}}'},
 {"/api/videos/3921/sections?",'{"code":0,"data":{"list":[{"id":52383,"title":"第01集"}],"pager":{"total":1}}}'},
 {"/api/videos/1730/sections?",'{"code":0,"data":{"list":[{"id":23051},{"id":23052},{"id":23053}],"pager":{"total":3}}}'},
 {"/api/v2/sections/52383/play-url",'{"code":0,"data":{"name":"CYC_Main","url":"https://media.test/cyc.m3u8"}}'},
 {"/api/v2/sections/23053/play-url",'{"code":500,"msg":"播放地址解析失败","data":null}'},
 {"media.test/cyc.m3u8","#EXTM3U\n#EXTINF:1540,\n1.ts\n#EXT-X-ENDLIST\n"},
 {"/playGV5926-1-3/",'<script>var player_aaaa={"encrypt":0,"url":"https://media.test/3.mp4","from":"test"};</script>'},
 {"media.test/3.mp4",box("moov",box("mvhd",string.rep("\0",12)..be(1000)..be(1471650)..string.rep("\0",80)))},
 {"api.bgm.tv/v0/episodes/126044",'{"id":126044,"duration_seconds":1470,"duration":"00:24:30"}'},
 {"api.bgm.tv/v0/episodes/126045",'{"id":126046,"duration_seconds":999}'},
 {"pcw-api.iq.com",'{"data":"123456"}'},
 {"baseinfo/123456",'{"data":{"durationSec":1445}}'},
 {"videos/show.json",'{"duration":"1445.25"}'},
 {"video/info?",'{"code":200,"data":{"info":{"time":"24:05"}}}'},
 {"listVodSactions.action",fixture("mdd_sactions.json")},
 {"pgc/view/web/season",fixture("bili_season.json")},
 {"pugv/view/web/season",'{"code":0,"data":{"episodes":[{"id":99,"cid":88,"duration":1445}]}}'},
 {"player/pagelist",'{"code":0,"data":[{"cid":10,"duration":10},{"cid":11,"duration":1445}]}'},
 {"/v/ac",fixture("acf_video_page.html")},
}
local deferred={}
call_cmd_async=function(args,cb)
 calls=calls+1
 recorded_calls[#recorded_calls+1]=args
 local url=args[#args];local response
 for _,pair in ipairs(responses) do if url:find(pair[1],1,true) then response=pair[2] end end
 deferred[#deferred+1]=function() if response then cb(nil,response) else cb("offline",nil) end end
end
call_cmd_async_with_timeout=function(args,timeout,cb) call_cmd_async(args,cb);return function() end end
local function drain() while #deferred>0 do local fn=table.remove(deferred,1);fn() end end
local function lookup(url,want,name)
 source_status.reset();DANMAKU.sources={[url]={}}
 source_status.ensure(url,"test")
 d.query(source_status.snapshot().entries,DANMAKU.sources);drain()
 check(name,DANMAKU.sources[url].duration_seconds==want)
end
lookup("https://www.bilibili.com/video/BVTEST?p=2",1445,"B站采用所选P秒数")
lookup("https://www.bilibili.com/bangumi/play/ep779775",1559.933,"B站番剧毫秒转秒")
lookup("https://www.bilibili.com/cheese/play/ep99",1445,"B站课程秒数不除1000")
lookup("https://www.iqiyi.com/v_test.html",1445,"爱奇艺补查")
lookup("https://v.youku.com/v_show/id_TEST.html",1445.25,"优酷补查")
lookup("https://www.mgtv.com/b/1/2.html",1445,"芒果分秒时长")
local mdd=utils.parse_json(fixture("mdd_sactions.json")).data[2]
lookup("https://www.mddcloud.com.cn/video/test.html?uuid="..mdd.uuid,2608,"埋堆堆按uuid选集")
lookup("https://www.acfun.cn/v/ac123?part=1",720.661,"AcFun分P毫秒时长")
lookup("https://www.bilibili.com/video/BVTEST?p=9",nil,"无效P不使用第一P时长")
local resolved
resolve_bilibili_episode_url({season_id="1"},1,function(url) resolved=url end)
drain()
local before_remembered=calls
lookup(resolved,1559.933,"B站选集结果直接复用时长")
check("B站已有分集信息不补发请求",calls==before_remembered)
lookup("https://ani.girigirilove.com/playGV5926-1-3/",1471.65,"girigirilove对应MP4实际时长")
lookup("https://api.animeko.org/episode/126044",nil,"animeko目录不伪装实测视频")
check("animeko目录参考明确标注",d.info("https://api.animeko.org/episode/126044").reference_seconds==1470)
lookup("https://api.animeko.org/episode/126045",nil,"Bangumi错集拒绝参考")
check("错集不提供参考时长",not d.info("https://api.animeko.org/episode/126045").reference_seconds)
lookup("https://www.yfsp.tv/play/3pTkJk5j9f6?id=fbrlqA5zaV9&videoId=490603&videoType=1",1451,"爱壹帆网页播放总时长")
lookup("https://www.yfsp.tv/play/3pTkJk5j9f6",1451,"爱壹帆无分集参数链接采用网页默认首集")
lookup("https://www.yfsp.tv/play/3pTkJk5j9f6?videoId=999",nil,"指定视频ID不存在不回退首集")
lookup("https://www.cycani.org/anime/3921/play/1?from=cychub",1540,"次元城零配置自动会话播放时长")
lookup("https://www.cycani.org/anime/1730/play/3",nil,"次元城解析失败保留未知")
local cyc_reason=d.info("https://www.cycani.org/anime/1730/play/3").reason
check("次元城反馈实际解析失败而非推断登录",cyc_reason:find("解析失败",1,true) and not cyc_reason:find("登录",1,true))
-- A configured header file selects v2 and must never reach the media host.
options.cyc_auth_header_file="tests/cyc-auth-placeholder.headers"
responses[#responses+1]={"/api/v2/sections/23053/play-url",'{"code":0,"data":{"name":"CYC_Main","url":"https://media.test/cyc.m3u8"}}'}
local auth_start=#recorded_calls
lookup("https://www.cycani.org/anime/1730/play/3?auth-test=1",1540,"次元城配置会话后查询 v2 时长")
local api_args,media_args
for i=auth_start+1,#recorded_calls do
 local a=recorded_calls[i]
 if a[#a]:find("/api/v2/sections/",1,true) then api_args=a end
 if a[#a]:find("media.test",1,true) then media_args=a end
end
local function has_arg(args,value)
 for _,v in ipairs(args or {}) do if v==value then return true end end
 return false
end
check("会话头文件仅用于 v2 接口",api_args and has_arg(api_args,"@tests/cyc-auth-placeholder.headers") and media_args and not has_arg(media_args,"@tests/cyc-auth-placeholder.headers"))
check("带会话请求不跟随重定向",api_args and not has_arg(api_args,"-L") and not has_arg(api_args,"--location"))
responses[#responses][2]='{"code":401,"msg":"unauthorized","data":null}'
lookup("https://www.cycani.org/anime/1730/play/3?auth-expired=1",nil,"次元城过期会话不提供时长")
local expired_reason=d.info("https://www.cycani.org/anime/1730/play/3?auth-expired=1").reason
check("过期会话说明需更新",expired_reason and expired_reason:find("会话",1,true) and expired_reason:find("更新",1,true))
options.cyc_auth_header_file=""
local before=calls
lookup("https://unknown.test/1",nil,"不支持源显示未知")
check("不支持源不发请求",calls==before)
if failures>0 then os.exit(1) end print("ALL PASS");os.exit(0)
