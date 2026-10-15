-- Full plugin registration and backwards-compatible script message contract.
local ROOT='D:/software/mpv-lazy/portable_config/scripts/uosc_danmaku'
package.path=ROOT..'/?.lua;'..package.path
require('modules/options')
options.danmaku_cache_enabled=false
options.history_path=ROOT..'/tests/timeline_main_history_tmp.json'
options.merge_enabled=false;options.density_control='off'
os.remove(options.history_path)
dofile(ROOT..'/main.lua')
local tl=require('modules/timeline')
local original=mp.get_property
mp.get_property=function(name,...) if name=='path' then return 'timeline-main-fixture.mkv' end return original(name,...) end
local a,b={},{};for i=1,30 do
 a[i]={time=i*20,text='事件'..i};b[i]={time=i*20+18,text='事件'..i}
end
DANMAKU={sources={a={data=a},b={data=b}}};tl.prepare()
local failures=0
local function check(n,c) print((c and 'PASS ' or 'FAIL ')..n);if not c then failures=failures+1 end end
local steps={
 function() mp.commandv('script-message','danmaku-delay','2','0','b') end,
 function()
  check('legacy source message uses independent manual layer',tl.map('b',218)==202 and tl.map('a',200)==200)
  mp.commandv('script-message','danmaku-delay','0','0','b')
 end,
 function()
  check('zero input preserves existing manual correction',tl.map('b',218)==202)
  tl.anchor('b',218,205,'group');tl.prepare()
  mp.commandv('script-message','danmaku-delay','-1','0','b')
 end,
 function()
  check('message tweak survives anchored rebuild',tl.map('b',218)==204 and tl.map('a',200)==203)
  check('new calibration never writes directory inheritance',read_file(HISTORY_PATH):find('timeline_calibration',1,true)~=nil)
  os.remove(HISTORY_PATH)
  print(failures==0 and 'ALL PASS' or 'FAILURES '..failures);os.exit(failures==0 and 0 or 1)
 end,
}
local index=0
local function step() index=index+1;steps[index]();if index<#steps then mp.add_timeout(0.1,step) end end
mp.add_timeout(0.1,step)
