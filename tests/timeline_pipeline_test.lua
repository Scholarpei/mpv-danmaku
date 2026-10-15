local ROOT='D:/software/mpv-lazy/portable_config/scripts/uosc_danmaku'
package.path=ROOT..'/?.lua;'..package.path
require('modules/options');require('modules/utils');require('modules/parse')
show_message=function() end
options.merge_enabled=false;options.density_control='off'
local fails=0
local function check(n,c) print((c and 'PASS ' or 'FAIL ')..n);if not c then fails=fails+1 end end
local function sources()
 local a,b={},{};for i=1,40 do
 a[i]={time=i*20,text='场景'..i,type=1,size=25,color=16777215}
 b[i]={time=i*20+18,text='场景'..i,type=1,size=25,color=16777215}
 end;return {a={data=a},b={data=b}} end
local original_get=mp.get_property
 local path='test-file-A.mkv'
 mp.get_property=function(name,...) if name=='path' then return path end return original_get(name,...) end
 HISTORY_PATH=ROOT..'/tests/timeline_history_tmp.json';os.remove(HISTORY_PATH)

DANMAKU={sources=sources()};convert_danmaku_to_ass_events(true)
local function time(url,raw)
 for _,e in ipairs(COMMENTS) do if e.source==url and e.orig_time==raw then return e.start_time end end
end
check('raw relative mapping enters playback',time('b',218)==200)
local ok,tl=pcall(require,'modules/timeline')
check('runtime timeline API available',ok)
if ok then
 check('group anchor accepted',tl.anchor('b',218,205,'group'))
 convert_danmaku_to_ass_events(true)
 check('playback uses local calibration',time('a',200)==205 and time('b',218)==205)
 local out=ROOT..'/tests/timeline_pipeline_tmp.xml';convert_danmaku_to_xml(out)
 local f=io.open(out);local xml=f:read('*a');f:close();os.remove(out)
 check('XML uses exactly the playback mapping',xml:find('p="205,1,25,16777215">场景10',1,true)~=nil)
 tl.adjust('b',-3,'group',318)
 convert_danmaku_to_ass_events(true)
 check('segment boundary uses original source coordinates',time('a',280)==285 and time('a',300)==302 and time('b',318)==302)
 tl.adjust('b',2,'source')
 convert_danmaku_to_ass_events(true)
 check('single source tweak survives repeated rebuilds',time('b',218)==207 and time('a',200)==205)
 check('clear source API exists',type(tl.clear_source)=='function')
 if tl.clear_source then tl.clear_source('b');convert_danmaku_to_ass_events(true);check('clear source keeps group anchor',time('b',218)==205 and time('a',200)==205) end
 tl.adjust('b',2,'source')
 tl.clear('source','b')
 DANMAKU.sources.b.delay_segments={{start=0,delay=7}}
 tl.adjust('b',2,'source')
 tl.clear_source('b');tl.undo();convert_danmaku_to_ass_events(true)
 check('undo also restores cleared legacy source delay',time('b',218)==214)
 tl.clear_source('b');tl.adjust('b',2,'source')
 options.timeline_align=false;convert_danmaku_to_ass_events(true)
 check('disabling relative analysis retains manual calibration on anchor source',time('b',218)==207)
 options.timeline_align=true
 tl.prepare()
 local before=tl.map('b',218)
 DANMAKU.sources.b.data[10].time=250;DANMAKU.sources.b.data[10].orig_time=250;DANMAKU.sources.b.data[10].text='内容已更改'
 tl.prepare()
 check('in-place data changes invalidate the cached calibration',tl.map('b',218)~=before and DANMAKU.sources.b.timeline_status:find('失效',1,true))
 DANMAKU.sources.b.data[10].time=218;DANMAKU.sources.b.data[10].orig_time=218;DANMAKU.sources.b.data[10].text='场景10'
 tl.prepare()
 tl.persist()
 DANMAKU={sources=sources()};convert_danmaku_to_ass_events(true)
 check('history reload restores the same file anchor and source tweak',time('b',218)==207)
 path='test-file-B.mkv'
 DANMAKU={sources=sources()};convert_danmaku_to_ass_events(true)
 check('history does not leak into a different file',time('b',218)==200)
 mp.get_property=original_get;HISTORY_PATH=nil;os.remove(ROOT..'/tests/timeline_history_tmp.json')
 DANMAKU={sources=sources()};convert_danmaku_to_ass_events(true)
 check('new file session does not inherit anchor',time('b',218)==200)
 local delayed=sources();delayed.b.delay_segments={{start=0,delay=-18}}
 DANMAKU={sources={b=delayed.b}};tl.prepare()
 DANMAKU.sources.a=delayed.a;tl.prepare()
 check('legacy delay restored before peers arrive is not applied twice',tl.map('b',218)==200)
 tl.anchor('b',218,205,'group')
 local zero={};for i=1,40 do zero[i]={time=i*20-40,text='场景'..i} end
 DANMAKU.sources['0']={data=zero};tl.prepare()
 check('anchored legacy-delay source stays fixed when group root changes',tl.map('b',218)==205)

 local left,right,bridge={},{},{}
 for i=1,30 do
  left[i]={time=i*20,text='左侧'..i};right[i]={time=i*20,text='右侧'..i}
  bridge[#bridge+1]=left[i];bridge[#bridge+1]=right[i]
 end
 DANMAKU={sources={a={data=left},b={data=right}}};tl.prepare()
 tl.anchor('a',200,205,'group');tl.anchor('b',200,250,'group')
 DANMAKU.sources.bridge={data=bridge};tl.prepare()
 check('late bridge preserves independent anchored positions on conflict',tl.map('a',200)==205 and tl.map('b',200)==250 and DANMAKU.sources.a.timeline_status:find('冲突',1,true))

end
if fails>0 then print(fails..' FAILURES');os.exit(1) end
print('ALL PASS');os.exit(0)
