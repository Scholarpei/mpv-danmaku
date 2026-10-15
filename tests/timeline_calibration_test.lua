local ROOT = 'D:/software/mpv-lazy/portable_config/scripts/uosc_danmaku'
package.path = ROOT .. '/?.lua;' .. package.path
local align = require('modules/timeline_align')
local fails = 0
local function check(n,c) print((c and 'PASS ' or 'FAIL ')..n); if not c then fails=fails+1 end end
local function pool(prefix,offset,n,start)
 local r={}; for i=1,n or 30 do r[#r+1]={time=(start or 0)+i*20+(offset or 0),text=prefix..i} end; return r
end
local function join(a,b) local r={}; for _,v in ipairs(a) do r[#r+1]=v end;for _,v in ipairs(b) do r[#r+1]=v end;return r end
local function src(u,e,d) return {url=u,entries=e,duration_seconds=d} end
local a=src('a',pool('正文',0),1453)
local b=src('b',pool('正文',18),1470)
local c=src('c',pool('独立',0),1452)
local r=align.compute({b,c,a})
check('duration is not a delay and disconnected source stays separate',r.groups and #r.groups==2 and r.shifts.b==-18 and not r.shifts.c)
check('one source still has a usable calibration group',align.compute({a}).groups and #align.compute({a}).groups==1)
local bridge=src('b',join(pool('左',10),pool('右',10)))
r=align.compute({src('a',pool('左',0)),bridge,src('c',pool('右',30))})
check('bridge connects sources without direct shared text',r.groups and #r.groups==1 and r.shifts.c==-30)
local jitter=pool('正文',18);for i,v in ipairs(jitter) do v.time=v.time+({-0.6,0,0.6})[(i%3)+1] end
r=align.compute({a,src('b',jitter)})
check('subsecond jitter shares a bounded cluster',r.shifts.b and math.abs(r.shifts.b+18)<0.01)
local repeated={};for i=1,300 do repeated[i]={time=i*4,text='哈哈哈'} end
r=align.compute({src('a',repeated),src('b',repeated)})
check('repeated generic text cannot establish a relation',r.groups and #r.groups==2)
local split=join(pool('前段',10,20),pool('后段',100,20,600))
local original=join(pool('前段',0,20),pool('后段',0,20,600))
r=align.compute({src('a',original),src('b',split)})
check('piecewise edit is reported without whole-source shift',r.pairs and r.pairs[1].segments and #r.pairs[1].segments==2 and #r.groups==2)
local segmented=align.compute({src('a',original),src('b',split)},{confirmed={{a='a',b='b',signature_a=r.signatures.a,signature_b=r.signatures.b,boundary=600,before=10,after=100}}})
check('confirmed edit joins groups with different offsets on either side',segmented.groups and #segmented.groups==1 and align.coordinate and align.coordinate(segmented,'b',300)==290 and align.coordinate(segmented,'b',900)==800)
local repeated_early={};for i=1,30 do repeated_early[#repeated_early+1]={time=i,text='常见短句'..i} end
r=align.compute({src('a',join(pool('正文',0),repeated_early)),src('b',join(pool('正文',18),repeated_early))})
check('competing offsets interleaved through the episode are not silently accepted',r.groups and #r.groups==2)
-- Each pair looks convincing alone, but their three offsets contradict.
local cycle=align.compute({
 src('a',join(pool('AB',0),pool('AC',0))),
 src('b',join(pool('AB',10),pool('BC',0))),
 src('c',join(pool('AC',30),pool('BC',10)))})
check('inconsistent cycle does not force a majority grouping',#cycle.groups==3 and cycle.members.a.conflict)
local ok,cal=pcall(require,'modules/timeline_calibration')
check('calibration module available',ok)
if ok then
 r=align.compute({a,b,c});local state=cal.new()
 cal.anchor(state,r,'b',218,205,'group',nil)
 check('anchor moves all related sources to local video',cal.map(state,r,'a',200)==205 and cal.map(state,r,'b',218)==205 and cal.map(state,r,'c',200)==200)
 cal.adjust(state,r,'a',-3,'group',300)
 check('segment preserves earlier timeline and uses shared coordinates',cal.map(state,r,'a',200)==205 and cal.map(state,r,'b',418)==402)
 cal.adjust(state,r,'b',2,'source',nil)
 check('source tweak does not move its peers',cal.map(state,r,'a',200)==205 and cal.map(state,r,'b',218)==207)
 cal.undo(state)
 check('undo restores previous mapping',cal.map(state,r,'b',218)==205)
 local restored=require('mp.utils').parse_json(require('mp.utils').format_json(state))
 check('serialized calibration restores exactly',cal.map(restored,r,'b',418)==402)
 local added=align.compute({src('0',pool('正文',-40)),a,b,c})
 check('new root does not move a calibrated timeline',cal.map(state,added,'a',200)==205 and cal.map(state,added,'0',160)==205)
 check('fresh file has no calibration',cal.map(cal.new(),r,'a',200)==200)
 local changed=align.compute({a,src('b',pool('changed',18)),c})
 check('changed anchor data invalidates saved calibration',cal.map(state,changed,'a',200)==200)
 local tied=align.compute({src('a',join(pool('一',0),pool('二',0))),src('b',join(pool('一',10),pool('二',30)))})
 check('two well-supported conflicting offsets cannot align whole source',#tied.groups==2)
 local segstate=cal.new()
 check('confirmed segmented source can be anchored to local video',cal.anchor(segstate,segmented,'b',300,295,'group'))
 check('segmented anchor propagates before and after edit',cal.map(segstate,segmented,'a',800)==805 and cal.map(segstate,segmented,'b',900)==805)
 check('inserted scene without counterpart is excluded',cal.map(segstate,segmented,'b',650)==nil)
 local three=align.compute({src('a',original),src('b',split)},{confirmed={{a='a',b='b',signature_a=segmented.signatures.a,signature_b=segmented.signatures.b,boundary=600,before=10,after=100,segments={{start=0,drift=10},{start=300,drift=40},{start=600,drift=100}}}}})
 check('confirmed multiple edit points retain separate offsets',align.coordinate(three,'b',250)==240 and align.coordinate(three,'b',440)==400 and align.coordinate(three,'b',900)==800)
 local separate=align.compute({src('a',pool('左侧',0)),src('b',pool('右侧',0))})
 local independent=cal.new()
 cal.anchor(independent,separate,'a',200,205,'group')
 cal.anchor(independent,separate,'b',200,250,'group')
 local merged=align.compute({src('a',pool('左侧',0)),src('b',pool('右侧',0)),src('bridge',join(pool('左侧',0),pool('右侧',0)))})
 check('independent conflicting anchors are detectable before merging',cal.conflicts and cal.conflicts(independent,merged)[merged.members.a.id])
 cal.clear(state,'group',r,'a')
 check('clear removes local calibration',cal.map(state,r,'a',200)==200)
end
if fails>0 then print(fails..' FAILURES');os.exit(1) end
print('ALL PASS');os.exit(0)
