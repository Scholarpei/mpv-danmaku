local ROOT='D:/software/mpv-lazy/portable_config/scripts/uosc_danmaku'
package.path=ROOT..'/?.lua;'..package.path
require('modules/options');require('modules/utils');require('modules/parse');require('modules/menu')
local tl=require('modules/timeline');local ui=require('modules/timeline_menu')
local fails=0;local function check(n,c) print((c and 'PASS ' or 'FAIL ')..n);if not c then fails=fails+1 end end
show_message=function() end
local data={};for i=1,30 do data[i]={time=i*20,text='画面事件'..i} end
DANMAKU={sources={a={provider='源A',data=data,duration_seconds=1453}}}
local props=ui.build()
check('calibration entry lists raw source with unverified status',props.items[1].hint:find('本地视频未确认',1,true)~=nil)
ui.select('a',10)
check('selection retains raw time and does not seek playback',ui.pending().raw==200)
check('confirm target calibrates the selected group',ui.confirm(205,false))
check('confirmed selection maps to chosen frame',tl.map('a',200)==205)
ui.select('a',10)
check('repeating a frame confirmation can replace the earlier anchor',ui.confirm(205,false) and tl.map('a',200)==205)
local snap=ui.build();check('calibrated state is visible',snap.items[1].hint:find('已人工校准',1,true)~=nil)
ui.adjust('a',-2,'group',true,300)
check('from-current-frame adjustment maps boundary back to raw timeline',tl.map('a',280)==285 and tl.map('a',300)==303)
ui.select('a',10);data[10].text='changed in place'
check('pending selection cannot use changed original content',not ui.confirm(205,false))
data[10].text='画面事件10'
ui.select('a',10);DANMAKU={sources={a={data=data}}}
check('pending selection cannot calibrate another session',not ui.confirm(205,false))
if fails>0 then print(fails..' FAILURES');os.exit(1) end
print('ALL PASS');os.exit(0)
