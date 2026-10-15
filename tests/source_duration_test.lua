local path = debug.getinfo(1,"S").source:sub(2)
local dir = path:match("^(.*)[/\\]") or "."
package.path = (dir:match("^(.*)[/\\]") or ".") .. "/?.lua;" .. package.path
local utils = require("mp.utils")
local failures = 0
local function check(name, ok)
    print((ok and "PASS " or "FAIL ") .. name)
    if not ok then failures=failures+1 end
end
local loaded, d = pcall(require,"modules/source_duration")
check("duration module available", loaded)
if not loaded then os.exit(1) end
show_message=function() end
source_status=require("modules/source_status")
DANMAKU={sources={}}
local playback="one.mkv"
mp.get_property=function(name, fallback) if name=="path" then return playback end return fallback end
local function source(url)
    source_status.ensure(url,"test")
    DANMAKU.sources[url]={data={1}}
    return DANMAKU.sources[url]
end
local s=source("test://one")
local write=d.capture("test://one")
write(1445)
check("duration reaches source",s.duration_seconds==1445)
check("duration reaches ledger",source_status.snapshot().entries[1].duration_seconds==1445)
source_status.mark_done("test://one",{count=1})
write(1450)
check("done entry can receive duration",source_status.snapshot().entries[1].duration_seconds==1450)
write(0); write(math.huge); write(0/0)
check("invalid duration cannot overwrite",s.duration_seconds==1450)
source_status.remove("test://one"); DANMAKU.sources["test://one"]=nil
local replacement=source("test://one")
write(999)
check("deleted and readded source rejects old callback",replacement.duration_seconds==nil)
write=d.capture("test://one"); playback="two.mkv"; write(999)
check("changed playback rejects old callback",replacement.duration_seconds==nil)
playback="one.mkv"
write=d.capture("test://one");source_status.reset();source_status.ensure("test://one","test");write(999)
check("new epoch rejects old callback",replacement.duration_seconds==nil)
local calls, pending=0,nil
d.register("^test://",function(url, cb) calls=calls+1; pending=cb end)
d.query(source_status.snapshot().entries,DANMAKU.sources)
d.query(source_status.snapshot().entries,DANMAKU.sources)
check("concurrent lookup deduplicated",calls==1)
check("lookup pending visible",d.pending("test://one"))
pending(nil)
d.query(source_status.snapshot().entries,DANMAKU.sources)
check("failed lookup not retried on refresh",calls==1 and not d.pending("test://one"))
source_status.reset();DANMAKU.sources={};s=source("test://two")
d.query(source_status.snapshot().entries,DANMAKU.sources);pending(1445)
check("async lookup reaches source",s.duration_seconds==1445)
check("metadata lookup preserves source status",source_status.snapshot().entries[1].status=="done")
source_status.ensure("test://failed","test");source_status.mark_failed("test://failed","network","test")
d.query(source_status.snapshot().entries,DANMAKU.sources);pending(1445)
local found
for _, e in ipairs(source_status.snapshot().entries) do if e.key=="test://failed" then found=e end end
check("failed source receives duration without changing status",found and found.duration_seconds==1445 and found.status=="failed")
source_status.reset();DANMAKU.sources={};s=source("remember://one")
d.remember("remember://one",1445)
d.query(source_status.snapshot().entries,DANMAKU.sources)
check("known episode metadata applied without lookup",s.duration_seconds==1445)
local fake_cache=require("modules/danmaku_cache")
local real_get,real_put=fake_cache.get,fake_cache.put
local stored, writes={}, 0
fake_cache.get=function(key) return stored[key] and {payload=stored[key]} end
fake_cache.put=function(key,value) writes=writes+1;stored[key]=value;return true end
source_status.reset();DANMAKU.sources={};s=source("cached://one")
d.capture("cached://one")(1445)
source_status.reset();DANMAKU.sources={};s=source("cached://one")
d.query(source_status.snapshot().entries,DANMAKU.sources)
check("cached duration restored without network",s.duration_seconds==1445)
check("reading metadata cache does not renew TTL",writes==1)
fake_cache.get,fake_cache.put=real_get,real_put

source_status.reset();DANMAKU.sources={};s=source("test://removed")
d.query(source_status.snapshot().entries,DANMAKU.sources)
local old_pending=pending
source_status.remove("test://removed");DANMAKU.sources["test://removed"]=nil
local newest=source("test://removed")
d.query(source_status.snapshot().entries,DANMAKU.sources)
old_pending(999)
check("removed source lookup does not write replacement",newest.duration_seconds==nil)
pending(1445)
check("replacement lookup still completes",newest.duration_seconds==1445)
local real_timeout=mp.add_timeout
local on_timeout
mp.add_timeout=function(_,fn) on_timeout=fn;return {kill=function() end} end
source_status.reset();DANMAKU.sources={};s=source("test://timeout")
d.query(source_status.snapshot().entries,DANMAKU.sources)
local late=pending
on_timeout()
check("lookup timeout ends querying state",not d.pending("test://timeout"))
late(999)
check("lookup completion after timeout ignored",s.duration_seconds==nil)
mp.add_timeout=real_timeout

d.register("^catalog://",function(_,cb) cb(nil,{reference_seconds=1470,reason="Bangumi 目录参考时长，并非源视频实测"}) end)
source_status.reset();DANMAKU.sources={};s=source("catalog://one")
d.query(source_status.snapshot().entries,DANMAKU.sources)
local info=d.info and d.info("catalog://one")
check("catalog reference separate from actual duration",not s.duration_seconds and info and info.reference_seconds==1470)
check("reference summary explicitly labeled",d.summary(nil,1452.65,false,info)=="参考 24:30（+17秒）")
check("unsupported source explains unknown",d.info and d.info("https://unsupported.test/1").reason:find("未接入"))
source_status.reset();DANMAKU.sources={}
check("reference cleared on playback reset",d.info and not d.info("catalog://one").reference_seconds)
for _,case in ipairs({
 {"https://www.cycani.org/anime/1730/play/3","尚未取得"},
 {"https://lanerc.life/vod/1860/3","加密"},
 {"https://www.yfsp.tv/play/test?id=3","尚未取得"},
 {"https://danmaku-api.test/api/v2/comment/85730003","聚合"},
}) do check("具体未知原因 "..case[2],d.info(case[1]).reason:find(case[2],1,true)~=nil) end
if failures>0 then os.exit(1) end
print("ALL PASS"); os.exit(0)
