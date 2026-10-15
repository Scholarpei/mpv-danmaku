-- mpv session adapter: one mapping for playback, export and calibration menus.
local align=require('modules/timeline_align')
local cal=require('modules/timeline_calibration')
local utils=require('mp.utils')
local M={}
local context,cached,cache_key,prepared_opts
local context_path
local function file_key()
 local path=mp.get_property('path')
 if path and type(is_protocol)=='function' and is_protocol(path) then path=remove_query(path) end
 return path
end
local function ensure()
 if context~=DANMAKU or context_path~=file_key() then
  local changed_path=context_path~=file_key()
  context=DANMAKU;context_path=file_key();cached=nil;cache_key=nil
  if changed_path and context then context.timeline_calibration=nil end
  if context and not cal.valid(context.timeline_calibration) then
   local raw=HISTORY_PATH and type(read_file)=='function' and read_file(HISTORY_PATH)
   local history=raw and utils.parse_json(raw);local entry=history and history[file_key()]
   context.timeline_calibration=entry and cal.valid(entry.timeline_calibration) and entry.timeline_calibration or cal.new()
  end
 end
 return context and context.timeline_calibration
end
local function legacy(source,raw,url)
 local state=ensure()
 for _,op in ipairs(state and state.operations or {}) do
  if op.source==url and op.reset_legacy then return 0 end
 end
 local sum=0
 for _,seg in ipairs(source.delay_segments or {}) do
  if raw>=(tonumber(seg.start) or 0) then sum=sum+(tonumber(seg.delay) or 0) end
 end
 if source.timeline_legacy_total and cached then
  local relative=align.coordinate(cached,url,raw)
  if relative then sum=sum-(relative-raw) end
 end
 return sum
end
function M.configure(opts) prepared_opts=opts;cache_key=nil end
function M.prepare(opts)
 local state=ensure();opts=opts or prepared_opts or {};prepared_opts=opts
 if not context then return {groups={},members={},signatures={},pairs={},shifts={}} end
 local key={tostring(options and options.timeline_align),tostring(options and options.timeline_align_min_match),tostring(options and options.chConvert)}
 local urls={};for u in pairs(context.sources or {}) do urls[#urls+1]=u end;table.sort(urls)
 local lists={}
 for _,u in ipairs(urls) do
  local s=context.sources[u]
  local checksum=5381
  if not s.blocked then for _,d in ipairs(s.data or {}) do
   local text=tostring(d.orig_time or d.time)..':'..tostring(d.text)
   for i=1,#text do checksum=(checksum*33+text:byte(i))%4294967291 end
  end end
  key[#key+1]=u..':'..tostring(s.blocked)..':'..tostring(checksum)

 end
 local k=table.concat(key,'|')
 if not cached or cache_key~=k then
  for _,u in ipairs(urls) do
   local s=context.sources[u]
   if not s.blocked and s.data and #s.data>0 then
    local entries={};for _,d in ipairs(s.data) do entries[#entries+1]={time=d.orig_time or d.time,text=d.text} end
    lists[#lists+1]={url=u,provider=s.provider,entries=entries,duration_seconds=s.duration_seconds}
   end
  end
  local confirmed={}
  for _,op in ipairs(state.operations) do if op.kind=='relation' then confirmed[#confirmed+1]=op end end
  cached=align.compute(lists,{transform=opts.transform,min_match_ratio=options and options.timeline_align_min_match,confirmed=confirmed})
  local conflicts=cal.conflicts(state,cached)
  local groups={}
  for _,g in ipairs(cached.groups) do
   if conflicts[g.id] then
    for _,u in ipairs(g.urls) do
     local single={id=u,root=u,urls={u},shifts={[u]=0},conflict=true,anchor_conflict=true}
     groups[#groups+1]=single;cached.members[u]=single;cached.shifts[u]=nil
    end
   else groups[#groups+1]=g end
  end
  cached.groups=groups
  cache_key=k
  if options and options.timeline_align==false then
   cached.groups={};cached.members={};cached.shifts={}
   for _,l in ipairs(lists) do
    local g={id=l.url,root=l.url,urls={l.url},shifts={[l.url]=0},disabled=true}
    cached.groups[#cached.groups+1]=g;cached.members[l.url]=g
   end
  end
 end
 context.timeline_analysis=cached
 for _,u in ipairs(urls) do
  local s=context.sources[u];local g=cached.members[u]
  if g then
   -- Old stored delays described total source correction. Preserve that initial
   -- total on migration; subsequent changes are independent source tweaks.
   if s.timeline_legacy_total==nil then
    s.timeline_legacy_total=#(s.delay_segments or {})>0
   end
   s.align_shift=options and options.timeline_align~=false and (cached.shifts[u] or 0) or nil
   s.align_pinned=nil
   local anchored,stale,partial=cal.status(state,cached,u)
   s.timeline_relation_status=#g.urls>1 and ('源间已关联（'..#g.urls..'源）') or '源间未关联'
   s.timeline_local_status=stale and '本地校准已失效，需复核' or (anchored and (partial and '本地视频已人工校准（含分段，请检查其他区段）' or '本地视频已人工校准') or '本地视频未确认')
   local best
   for _,p in ipairs(cached.pairs) do
    if p.a==u or p.b==u then
     if not best or p.independent>best.independent or (p.independent==best.independent and p.score>best.score) then best=p end
    end
   end
   local count=#(s.data or {})
   if #g.urls>1 then
    s.timeline_relation_detail='已应用源间相对偏移；选一句弹幕确认视频位置，可校准整组'
   elseif count<6 then
    s.timeline_relation_detail='仅'..count..'条弹幕，至少需要6个独立同文匹配；保留原时间'
   elseif best then
    local peer=best.a==u and best.b or best.a
    local label=context.sources[peer].provider or peer
    s.timeline_relation_detail=string.format('与%s：%d个独立匹配，重合%.0f%%，偏移集中%.0f%%；%s；保留原时间',label,best.independent,(best.overlap or 0)*100,(best.concentration or 0)*100,best.reason)
   else s.timeline_relation_detail='没有其他可比对源；保留原时间' end
   if g.conflict then s.timeline_relation_status='源间关联冲突';s.timeline_relation_detail=g.anchor_conflict and '人工锚点冲突，请删除矛盾校准后重试' or '关联冲突，待确认' end
   if g.disabled then s.timeline_relation_status='自动关联已关闭';s.timeline_relation_detail='保留各源原始时间与手动校准' end
   s.timeline_status=s.timeline_relation_status..' · '..s.timeline_local_status
  else
   s.align_shift=nil;s.timeline_status=nil;s.timeline_relation_status=nil;s.timeline_local_status=nil;s.timeline_relation_detail=nil
  end
 end
 return cached
end
function M.map(url,raw)
 local state=ensure();local r=cached or M.prepare();local s=context and context.sources[url]
 if not s then return raw end
 local mapped=cal.map(state,r,url,raw,function(u,t,snapshot)
  if type(snapshot)~='table' then return 0 end
  local coord=align.coordinate(r,u,t)
  return snapshot.offset-(snapshot.total and coord and (coord-t) or 0)
 end);if not mapped then return nil end
 local t=mapped+legacy(s,raw,url)
 return math.max(0,t)
end
-- Map a player position back to original source coordinates. Enumerating
-- constant-offset intervals avoids using shifted player seconds as raw seconds.
function M.raw_at(url,frame)
 if type(frame)~='number' or frame<0 or frame~=frame or frame==math.huge then return nil end
 local r=M.prepare();local boundaries={0};local state=ensure()
 for _,op in ipairs(state.operations) do
  if op.source==url and op.start then boundaries[#boundaries+1]=op.start end
 end
 local source=context.sources[url]
 if not source then return nil end
 for _,seg in ipairs(source.delay_segments or {}) do boundaries[#boundaries+1]=seg.start end
 -- Every source timestamp and projected operation boundary is a safe sample of
 -- its interval. Fixed-point candidates then recover subsecond positions.
 for _,d in ipairs(source.data or {}) do boundaries[#boundaries+1]=d.orig_time or d.time end
 for _,op in ipairs(state.operations) do
  if op.start and r.members[op.source]==r.members[url] then
   local at=align.coordinate(r,op.source,op.start)
   if at then boundaries[#boundaries+1]=at-(r.shifts[url] or 0) end
  end
 end
 local found=nil
 for _,raw in ipairs(boundaries) do
  local mapped=M.map(url,raw)
  if mapped then
   local candidate=frame-(mapped-raw)
   if candidate>=0 then
    local check=M.map(url,candidate)
    if check and math.abs(check-frame)<0.001 then
     if found and math.abs(found-candidate)>0.001 then return nil end
     found=candidate
    end
   end
  end
 end
 return found
end
function M.persist()
 local state=ensure();local path=file_key()
 if not state or not path or not HISTORY_PATH or type(write_json_file)~='function' then return end
 local raw=read_file(HISTORY_PATH);local history=raw and utils.parse_json(raw) or {}
 history=history or {};history[path]=history[path] or {};history[path].timeline_calibration=state
 for url,s in pairs(context.sources or {}) do
  local record=history[path].sources and history[path].sources[url]
  if record then record.timeline_legacy_total=s.timeline_legacy_total end
 end
 write_json_file(HISTORY_PATH,history)
end
local function changed(ok)
 if not ok then return false end
 cache_key=nil;M.persist();if type(load_danmaku)=='function' then load_danmaku(true) end
 return true
end
function M.anchor(url,raw,target,scope,start)
 local r=M.prepare();local s=context and context.sources[url]
 if not s then return false end
 -- Final manual layer stays intact; anchor compensates its value at this point.
 local function snapshot(u,t,saved)
  if type(saved)=='table' then
   local coord=align.coordinate(r,u,t)
   return saved.offset-(saved.total and coord and (coord-t) or 0)
  end
  local source=context.sources[u]
  local total=source.timeline_legacy_total
  for _,op in ipairs(ensure().operations) do if op.source==u and op.reset_legacy then total=false end end
  local coord=align.coordinate(r,u,t) or t
  return {offset=legacy(source,t,u)+(total and (coord-t) or 0),total=total}
 end
 return changed(cal.anchor(ensure(),r,url,raw,target,scope,start,snapshot))
end
function M.adjust(url,delta,scope,start) return changed(cal.adjust(ensure(),M.prepare(),url,delta,scope,start)) end
function M.confirm(index,boundary) return changed(cal.confirm(ensure(),M.prepare(),index,boundary)) end
function M.clear_source(url)
 return changed(cal.clear_source(ensure(),M.prepare(),url))
end
function M.undo() return changed(cal.undo(ensure())) end
function M.remove(i) return changed(cal.remove(ensure(),i)) end
function M.clear(scope,url) return changed(cal.clear(ensure(),scope,M.prepare(),url)) end
function M.operations() local state=ensure();return state and state.operations or {} end
function M.state() return ensure() end
function M.reset() context=nil;context_path=nil;cached=nil;cache_key=nil end
return M
