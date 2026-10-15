-- Run with mpv.com --idle=once --no-config --script=tests/global_delay_test.lua
local ROOT=(debug.getinfo(1,'S').source:sub(2):gsub('\\','/'):match('^(.*)/') or '.')..'/..'
package.path=ROOT..'/?.lua;'..package.path
require('modules/options')
options.timeline_align=false;options.merge_enabled=false;options.density_control='off'
options.blacklist_path=''
require('modules/utils');require('modules/parse')
local failures=0
local function check(name,ok)
 print((ok and 'PASS ' or 'FAIL ')..name)
 if not ok then failures=failures+1 end
end
local ok,offset=pcall(require,'modules/global_delay')
check('independent final offset is available',ok)
if not ok then print('FAILURES '..failures);os.exit(1) end
local real_get=mp.get_property
local path='global-delay-A.mkv'
mp.get_property=function(name,...) if name=='path' then return path end return real_get(name,...) end
local last_message
show_message=function(text) last_message=text end
local function sources()
 return {a={delay_segments={{start=0,delay=2}},data={
  {time=5.2,type=5,text='fixed',size=25,color=16777215},
 }},b={delay_segments={{start=0,delay=3}},data={
  {time=10.2,type=1,text='scrolling',size=25,color=16777215},
 }}}
end
local function event(text)
 for _,e in ipairs(COMMENTS or {}) do if e.clean_text==text then return e end end
end
DANMAKU={sources=sources()};convert_danmaku_to_ass_events(true)
check('existing source offsets are applied first',math.abs(event('fixed').start_time-7.2)<0.001 and event('scrolling').start_time==13)
local original=COMMENTS
check('fractional final shift is accepted',offset.adjust(0.5))
check('final shift follows rounding and applies to both sources',math.abs(event('fixed').start_time-7.7)<0.001 and event('scrolling').start_time==13.5)
check('event duration and layout are preserved',event('scrolling').end_time==28.5 and event('scrolling').text==original[2].text)
check('source data and source delay records stay intact',DANMAKU.sources.b.data[1].time==10.2 and DANMAKU.sources.b.delay_segments[1].delay==3)
convert_danmaku_to_ass_events(true)
check('rebuilding does not compound the final shift',event('scrolling').start_time==13.5)
DANMAKU.sources.c={data={{time=20,type=4,text='late source',size=25,color=16777215}}}
convert_danmaku_to_ass_events(true)
check('late arriving sources inherit the final shift',event('late source').start_time==20.5)
DANMAKU={sources=sources()};convert_danmaku_to_ass_events(true)
check('replacing the source session within a video preserves offset',offset.get()==0.5 and event('scrolling').start_time==13.5)
local before=COMMENTS
check('invalid and overflowing inputs are rejected',not offset.adjust(0/0) and not offset.adjust(math.huge) and not offset.adjust('bad') and offset.get()==0.5 and COMMENTS==before)
offset.set(-8)
check('negative starts are omitted rather than piled at zero',event('fixed')==nil and event('scrolling').start_time==5)
offset.set(0)
check('reset restores omitted events without changing layout',math.abs(event('fixed').start_time-7.2)<0.001 and event('scrolling').text==original[2].text)
offset.set(-8)
local output=ROOT..'/tests/global_delay_tmp.xml'
check('shifted XML can be exported',convert_danmaku_to_xml(output))
local f=assert(io.open(output));local xml=f:read('*a');f:close();os.remove(output)
check('XML uses final shift and omits negative timestamps',xml:find('fixed',1,true)==nil and xml:find('p="5.2,1,25,16777215">scrolling',1,true)~=nil)
check('XML export leaves displayed events intact',event('scrolling').start_time==5)
path='global-delay-B.mkv';DANMAKU={sources=sources()};convert_danmaku_to_ass_events(true)
check('a different video starts at zero',offset.get()==0 and event('scrolling').start_time==13)
DANMAKU.sources={};convert_danmaku_to_ass_events(true);offset.adjust(1)
check('empty source rebuild cannot resurrect stale comments',#COMMENTS==0)
DANMAKU={sources=sources()};convert_danmaku_to_ass_events(true)
local steps={
 function() mp.commandv('script-message','danmaku-global-delay','-1') end,
 function()
  check('advance message subtracts one second',offset.get()==0 and event('scrolling').start_time==13)
  mp.commandv('script-message','danmaku-global-delay','1')
 end,
 function()
  check('delay message adds one second and reports total',offset.get()==1 and event('scrolling').start_time==14 and last_message:find('+1',1,true))
  local props=offset.menu()
  check('menu exposes advance delay and reset',#props.items>=4)
  local reset
  for _,item in ipairs(props.items) do if item.value and item.value[3]=='danmaku-global-delay-reset' then reset=item.value end end
  check('menu reset action exists',reset~=nil)
  if reset then mp.commandv(unpack(reset)) end
 end,
 function()
  check('menu reset command restores zero',offset.get()==0 and event('scrolling').start_time==13)
  mp.commandv('script-message','danmaku-global-delay','nan')
 end,
 function()
  check('invalid message cannot poison the offset',offset.get()==0 and event('scrolling').start_time==13)
  mp.get_property=real_get
  print(failures==0 and 'ALL PASS' or 'FAILURES '..failures);os.exit(failures==0 and 0 or 1)
 end,
}
local index=0
local function step() index=index+1;steps[index]();if index<#steps then mp.add_timeout(0.05,step) end end
mp.add_timeout(0.05,step)
