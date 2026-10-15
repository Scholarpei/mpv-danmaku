-- Rejecting uncertain relations must explain the evidence without hiding successful ones.
local ROOT='D:/software/mpv-lazy/portable_config/scripts/uosc_danmaku'
package.path=ROOT..'/?.lua;'..package.path
require('modules/options');require('modules/utils');require('modules/parse');require('modules/menu')
show_message=function() end
local align=require('modules/timeline_align')
local tl=require('modules/timeline');local ui=require('modules/timeline_menu')
local failures=0
local function check(name,ok) print((ok and 'PASS ' or 'FAIL ')..name);if not ok then failures=failures+1 end end
local a,b={},{}
for i=1,30 do a[i]={time=i*20,text='对应画面'..i};b[i]={time=i*20+18,text='对应画面'..i} end
local r=align.compute({{url='a',entries=a},{url='sparse',entries={{time=100,text='其他内容'},{time=400,text='另一条'}}}})
local p=r.pairs[1]
check('no matches have finite zero coverage',p.coverage==0)
check('rejection exposes measured overlap and available comments',p.overlap==0 and p.min_count==2 and type(p.failures)=='table' and #p.failures>0)
DANMAKU={sources={a={provider='源A',data=a},b={provider='源B',data=b},sparse={provider='稀疏源',data={{time=200,text='独有内容'}}}}}
tl.prepare()
check('relative success remains visible before local confirmation',DANMAKU.sources.a.timeline_relation_status=='源间已关联（2源）' and DANMAKU.sources.a.timeline_local_status=='本地视频未确认')
check('sparse source explains why it remains independent',DANMAKU.sources.sparse.timeline_relation_detail and DANMAKU.sources.sparse.timeline_relation_detail:find('1条',1,true)~=nil)
local built=ui.build();local all='';for _,item in ipairs(built.items) do all=all..item.title..' '..(item.hint or '')..'\n' end
check('menu summarizes established relations separately from video confirmation',all:find('已关联 2 个源',1,true) and all:find('独立 1 个源',1,true) and all:find('本地视频：已确认 0 个源',1,true))
tl.anchor('a',200,205,'group');tl.prepare()
check('one local anchor confirms the connected group only',DANMAKU.sources.a.timeline_local_status=='本地视频已人工校准' and DANMAKU.sources.b.timeline_local_status=='本地视频已人工校准' and DANMAKU.sources.sparse.timeline_local_status=='本地视频未确认')
if failures>0 then print(failures..' FAILURES');os.exit(1) end
print('ALL PASS');os.exit(0)
