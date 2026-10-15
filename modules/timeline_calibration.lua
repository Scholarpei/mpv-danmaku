-- Versioned per-file operations. Boundaries are original timestamps in the
-- reference source, so rebuilding/re-rooting cannot move a confirmed edit point.
local M={}
local align=require('modules/timeline_align')
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
function M.new() return {version=1,operations={},undo={}} end
function M.valid(state) return type(state)=='table' and state.version==1 and type(state.operations)=='table' end
local function copy(v)
 if type(v)~='table' then return v end
 local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r
end
local function save(state)
 state.undo=state.undo or {};state.undo[#state.undo+1]=copy(state.operations)
 if #state.undo>30 then table.remove(state.undo,1) end
end
local function applicable(op,result,url,scope)
 return op.scope==scope and result.signatures[op.source]==op.signature
  and ((scope=='source' and op.source==url) or
   (scope=='group' and result.members[op.source] and result.members[op.source]==result.members[url]))
end
local function group_offset(state,result,url,t,manual)
 local total=0;local group=result.members[url]
 if not group or not M.valid(state) then return total end
 for _,op in ipairs(state.operations) do
  if applicable(op,result,url,'group') then
   local at=op.start and align.coordinate(result,op.source,op.start)
   local ref=op.kind=='anchor' and align.coordinate(result,op.source,op.raw)
   if (not op.start or (at and t>=at)) and (op.kind~='anchor' or ref) then
    if op.kind=='anchor' then total=op.target-ref-((op.manual and manual) and manual(op.source,op.raw,op.manual) or 0)
    else total=total+op.delta end
   end
  end
 end
 return total
end
function M.map(state,result,url,raw,manual)
 local group=result.members[url]
 local t=align.coordinate(result,url,raw)
 if not t then return nil end
 t=t+group_offset(state,result,url,t,manual)
 if M.valid(state) then for _,op in ipairs(state.operations) do
  if applicable(op,result,url,'source') and (not op.start or raw>=op.start) then t=t+op.delta end
 end end
 return t
end
-- Detect independently established local origins before joining their groups.
-- A later whole-group anchor explicitly supersedes overlapping older anchors.
function M.conflicts(state,result)
 local active={};local conflicts={}
 if not M.valid(state) then return conflicts end
 for _,op in ipairs(state.operations) do
  if op.kind=='anchor' and not op.start and applicable(op,result,op.source,'group') then
   for i=#active,1,-1 do
    local old=active[i];local overlap=old.source==op.source
    for u in pairs(op.peers or {[op.source]=true}) do if (old.peers or {[old.source]=true})[u] then overlap=true end end
    if overlap then table.remove(active,i) end
   end
   active[#active+1]=op
  end
 end
 for i,a in ipairs(active) do for j=i+1,#active do
  local b=active[j];local ga,gb=result.members[a.source],result.members[b.source]
  if ga and ga==gb then
   local ta,tb=align.coordinate(result,a.source,a.raw),align.coordinate(result,b.source,b.raw)
   if ta and tb and math.abs((a.target-ta)-(b.target-tb))>2 then conflicts[ga.id]=true end
  end
 end end
 return conflicts
end
function M.status(state,result,url)
 local calibrated,stale,partial=false,false,false
 if M.valid(state) then for _,op in ipairs(state.operations) do
  if applicable(op,result,url,'group') and op.kind=='anchor' then
    calibrated=true;if op.start then partial=true else partial=false end
   end
  if op.source==url and result.signatures[url]~=op.signature then stale=true end
   if op.kind=='relation' and (op.a==url or op.b==url)
    and (result.signatures[op.a]~=op.signature_a or result.signatures[op.b]~=op.signature_b) then stale=true end
 end end
 return calibrated,stale,partial
end
local function append(state,result,url,op)
 if not M.valid(state) or not result.members[url] then return false end
 save(state);op.source=url;op.signature=result.signatures[url]
 state.operations[#state.operations+1]=op;return true
end
function M.anchor(state,result,url,raw,target,scope,start,manual)
 if not finite(raw) or not finite(target) or (start~=nil and not finite(start)) then return false end
 if scope=='source' then
  return M.adjust(state,result,url,target-M.map(state,result,url,raw),scope,start)
 end
 -- Source tweaks remain the final layer; account for them in the selected anchor.
 local g=result.members[url];if not g then return false end
 local coord=align.coordinate(result,url,raw);if not coord then return false end
 local tweak=M.map(state,result,url,raw,manual)-(coord+group_offset(state,result,url,coord,manual))
 local peers={};for _,u in ipairs(g.urls) do peers[u]=true end
 return append(state,result,url,{scope='group',kind='anchor',raw=raw,target=target-tweak,start=start,peers=peers,manual=manual and manual(url,raw) or nil})
end
function M.adjust(state,result,url,delta,scope,start)
 if not finite(delta) or (start~=nil and not finite(start)) then return false end
 if delta==0 then return true end
 return append(state,result,url,{scope=scope=='source' and 'source' or 'group',kind='adjust',delta=delta,start=start})
end
function M.confirm(state,result,index,boundaries)
 local p=result.pairs[index]
 if not p or not p.segments or #p.segments<2 then return false end
 if type(boundaries)=='number' then boundaries={boundaries} end
 if type(boundaries)~='table' or #boundaries~=#p.segments-1 then return false end
 local segments={{start=-math.huge,drift=p.segments[1].drift}}
 local previous=-math.huge
 for i,b in ipairs(boundaries) do
  if not finite(b) or b<=previous or b<p.segments[1].start or b>p.segments[#p.segments].finish then return false end
  segments[#segments+1]={start=b,drift=p.segments[i+1].drift};previous=b
 end
 -- JSON has no infinity: the first interval always begins at original zero.
 segments[1].start=0
 return append(state,result,p.a,{scope='relation',kind='relation',a=p.a,b=p.b,
  signature_a=result.signatures[p.a],signature_b=result.signatures[p.b],segments=segments,
  boundary=boundaries[1],before=p.segments[1].drift,after=p.segments[#p.segments].drift})
end
function M.undo(state)
 if not M.valid(state) or not state.undo or #state.undo==0 then return false end
 state.operations=table.remove(state.undo);return true
end
function M.clear_source(state,result,url)
 if not M.valid(state) or not result.members[url] then return false end
 save(state)
 for i=#state.operations,1,-1 do
  if state.operations[i].scope=='source' and state.operations[i].source==url then table.remove(state.operations,i) end
 end
 state.operations[#state.operations+1]={scope='source',kind='adjust',delta=0,reset_legacy=true,source=url,signature=result.signatures[url]}
 return true
end
function M.remove(state,index)
 if not M.valid(state) or not state.operations[index] then return false end
 save(state);table.remove(state.operations,index);return true
end
function M.clear(state,scope,result,url)
 if not M.valid(state) then return false end
 save(state)
 for i=#state.operations,1,-1 do
  local op=state.operations[i]
  if not scope or (op.scope==scope and (op.source==url or applicable(op,result,url,scope))) then table.remove(state.operations,i) end
 end
 return true
end
return M
