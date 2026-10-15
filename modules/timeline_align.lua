-- Relative source relationships only. Durations never determine offsets.
-- Pure Lua: entries must contain original (unadjusted) timestamps.
local M = {}
local CJK_PUNCTS = {
    "，", "。", "！", "？", "、", "；", "：",
    "“", "”", "‘", "’",
    "（", "）", "《", "》", "【", "】", "「", "」", "『", "』",
    "·", "—", "–", "…", "～", "　",
    "＜", "＞", "＝", "＋", "－", "＊", "／", "＼", "＠", "＃", "＆", "％", "｜",
}

-- 归一化文本（跨源匹配键）：transform（简繁归一）→ 去 ASCII 空白标点 + CJK 标点
-- → ASCII 小写。纯标点/空白归一后为空则返回 nil（不参与匹配）
local function normalize_text(text, transform)
    if type(text) ~= "string" or text == "" then return nil end
    if transform then
        text = transform(text)
        if type(text) ~= "string" or text == "" then return nil end
    end
    text = text:gsub("[%s%p]", "")
    for i = 1, #CJK_PUNCTS do
        text = text:gsub(CJK_PUNCTS[i], "")
    end
    if text == "" then return nil end
    return text:lower()
end


local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function median(points)
 table.sort(points,function(a,b) return a.d<b.d end)
 local total=0;for _,p in ipairs(points) do total=total+p.w end
 local sum=0;for _,p in ipairs(points) do sum=sum+p.w;if sum>=total/2 then return p.d end end
 return 0
end
local function index(item,opts)
 local x={url=item.url,provider=item.provider,map={},count=0,lo=math.huge,hi=0}
 local fingerprint={}
 for _,e in ipairs(item.entries) do
  local t=tonumber(e.time);local key=normalize_text(e.text,opts.transform)
  if finite(t) and key then
   x.count=x.count+1;x.lo=math.min(x.lo,t);x.hi=math.max(x.hi,t)
   local v=x.map[key];if not v then v={};x.map[key]=v end
   v[#v+1]=t
   fingerprint[#fingerprint+1]=key..'@'..string.format('%.3f',t)
  end
 end
 -- Compact order-independent content identity; no dependency on mp or crypto.
 table.sort(fingerprint);local h=5381
 for _,s in ipairs(fingerprint) do for i=1,#s do h=(h*33+s:byte(i))%4294967291 end end
 x.signature=tostring(h)..':'..x.count
 for _,v in pairs(x.map) do table.sort(v) end
 return x
end
-- Sorted sliding window + prefix weights: O(n log n), including dense pools
-- where thousands of comments have exactly the same offset.
local function cluster(points,tolerance)
 table.sort(points,function(a,b) if a.d~=b.d then return a.d<b.d end return a.key<b.key end)
 local prefix={[0]=0};for i,p in ipairs(points) do prefix[i]=prefix[i-1]+p.w end
 local function lower(value)
  local lo,hi=1,#points+1
  while lo<hi do local mid=math.floor((lo+hi)/2);if points[mid].d<value then lo=mid+1 else hi=mid end end
  return lo
 end
 local function upper(value)
  local lo,hi=1,#points+1
  while lo<hi do local mid=math.floor((lo+hi)/2);if points[mid].d<=value then lo=mid+1 else hi=mid end end
  return lo-1
 end
 local best={points={},weight=0};local left=1;local bestleft,bestright
 for right,p in ipairs(points) do
  while p.d-points[left].d>tolerance*2 do left=left+1 end
  local half=(prefix[right]+prefix[left-1])/2
  local lo,hi=left,right
  while lo<hi do local mid=math.floor((lo+hi)/2);if prefix[mid]<half then lo=mid+1 else hi=mid end end
  local center=points[lo].d
  local first,last=lower(center-tolerance),upper(center+tolerance)
  local weight=prefix[last]-prefix[first-1]
  if weight>best.weight+1e-9 then best.weight=weight;bestleft=first;bestright=last end
 end
 if bestleft then
  for i=bestleft,bestright do best.points[#best.points+1]=points[i] end
  best.drift=median(best.points)
 end
 return best
end
local function pair(a,b,opts)
 local points,matched,unique={},0,0
 local min_count=math.min(a.count,b.count)
 local keys={};for k in pairs(a.map) do if b.map[k] then keys[#keys+1]=k end end;table.sort(keys)
 for _,key in ipairs(keys) do
  local aa,bb=a.map[key],b.map[key];matched=matched+math.min(#aa,#bb)
  -- Repeated slogans cannot dominate; ambiguous cross-products have bounded cost.
  if #aa<=8 and #bb<=8 then
   unique=unique+1
   for _,ta in ipairs(aa) do for _,tb in ipairs(bb) do
    points[#points+1]={d=tb-ta,a=ta,b=tb,key=key,w=1/(#aa*#bb)}
   end end
  end
 end
 local best=cluster(points,opts.tolerance or 2)
 local other={};for _,p in ipairs(points) do if math.abs(p.d-(best.drift or 0))>(opts.tolerance or 2)*2 then other[#other+1]=p end end
 local runner=cluster(other,opts.tolerance or 2)
 local ambiguous=best.weight>0 and runner.weight>=best.weight*0.8
 -- A text contributes at most one unit and one representative correspondence.
 local by_key={}
 for _,p in ipairs(best.points) do
  local q=by_key[p.key]
  if not q or math.abs(p.d-best.drift)<math.abs(q.d-best.drift) then by_key[p.key]=p end
 end
 local support={};local lo,hi=math.huge,-math.huge
 for _,p in pairs(by_key) do support[#support+1]=p;lo=math.min(lo,p.a);hi=math.max(hi,p.a) end
 table.sort(support,function(x,y) return x.a<y.a end)
 -- Order consistency removes repeated-text matches to a different scene.
 local ordered=0;local last=-math.huge
 for _,p in ipairs(support) do if p.b>=last then ordered=ordered+1;last=p.b end end
 local span=math.min(a.hi-a.lo,b.hi-b.lo)
 local d={a=a.url,b=b.url,url=b.url,provider=b.provider,drift=best.drift or 0,
  votes=#support,match_count=matched,independent=#support,applied=false,reliable=false,
  score=best.weight,coverage=#support>1 and span>0 and (hi-lo)/span or 0,
  min_count=min_count,overlap=min_count>0 and matched/min_count or 0,
  effective_ratio=best.weight/math.max(1,min_count),
  concentration=best.weight/math.max(1,unique),order_ratio=ordered/math.max(1,#support),failures={}}
 local threshold=tonumber(opts.min_match_ratio) or 0.3
 if threshold<=0 or threshold>1 then threshold=0.3 end
 local function reject(condition,reason) if condition then d.failures[#d.failures+1]=reason end end
 reject(min_count==0 or d.overlap<threshold,'文本重合率过低')
 reject(#support<6 or d.effective_ratio<0.05,'独立文本/有效票率不足')
 reject(d.concentration<0.5 or d.order_ratio<0.8,'偏移集中度不足或顺序冲突')
 reject(ambiguous,'多个偏移候选接近，需人工确认')
 reject(d.coverage<0.25,'支持时间跨度过窄')
 d.reliable=#d.failures==0;d.reason=d.failures[1] or '全片关系稳定'
 -- Validate time windows independently. Never apply an inferred edit boundary.
 local bins={};local width=math.max(1,(a.hi-a.lo)/4)
 for _,p in ipairs(points) do
  local k=math.min(4,math.floor((p.a-a.lo)/width)+1)
  bins[k]=bins[k] or {};bins[k][#bins[k]+1]=p
 end
 local segments={}
 for k=1,4 do if bins[k] then
  local c=cluster(bins[k],opts.tolerance or 2);local seen={};local n=0;local total=0
  for _,p in ipairs(bins[k]) do total=total+p.w end
  for _,p in ipairs(c.points) do if not seen[p.key] then seen[p.key]=true;n=n+1 end end
  if n>=6 and c.weight/math.max(total,1)>=0.6 then
   local seg=segments[#segments]
   if seg and math.abs(seg.drift-c.drift)<=(opts.tolerance or 2) then seg.finish=a.lo+k*width
   else segments[#segments+1]={start=a.lo+(k-1)*width,finish=a.lo+k*width,drift=c.drift,support=n} end
  end
 end end
 if #segments>1 then d.reliable=false;d.reason='疑似分段剪辑差异，需确认边界';d.failures[#d.failures+1]=d.reason;d.segments=segments end
 return d
end
function M.compute(lists,opts)
 opts=opts or {}
 local r={shifts={},baseline=nil,diag={},pairs={},groups={},members={},signatures={}}
 local active={}
 for _,item in ipairs(lists or {}) do
  if item.url and type(item.entries)=='table' and #item.entries>0 then
   local x=index(item,opts);active[#active+1]=x;r.signatures[x.url]=x.signature
  end
 end
 table.sort(active,function(a,b) return a.url<b.url end)
 local edges={};local adjacency={}
 for _,x in ipairs(active) do adjacency[x.url]={} end
 for i=1,#active do for j=i+1,#active do
  local d=pair(active[i],active[j],opts);r.pairs[#r.pairs+1]=d
  if d.reliable then edges[#edges+1]=d end
 end end
 for _,c in ipairs(opts.confirmed or {}) do
  if r.signatures[c.a]==c.signature_a and r.signatures[c.b]==c.signature_b
   and finite(c.boundary) and finite(c.before) and finite(c.after) and adjacency[c.a] and adjacency[c.b] then
   edges[#edges+1]={a=c.a,b=c.b,drift=c.before,score=math.huge,reliable=true,confirmed=c}
  end
 end
 table.sort(edges,function(a,b) if a.score~=b.score then return a.score>b.score end return a.a..'|'..a.b<b.a..'|'..b.b end)
 local parent={};for _,x in ipairs(active) do parent[x.url]=x.url end
 local function find(u) if parent[u]~=u then parent[u]=find(parent[u]) end;return parent[u] end
 for _,e in ipairs(edges) do
  if find(e.a)~=find(e.b) then
   parent[find(e.b)]=find(e.a)
   adjacency[e.a][#adjacency[e.a]+1]={url=e.b,shift=-e.drift,edge=e,reverse=false}
   adjacency[e.b][#adjacency[e.b]+1]={url=e.a,shift=e.drift,edge=e,reverse=true}
  end
 end
 local seen={}
 for _,x in ipairs(active) do if not seen[x.url] then
  local g={id=x.url,root=x.url,urls={},shifts={},paths={},calibrated=false}
  local function visit(u,s,path)
   if seen[u] then return end;seen[u]=true;g.urls[#g.urls+1]=u;g.shifts[u]=s;g.paths[u]=path
   for _,v in ipairs(adjacency[u]) do
    local nextpath={v};for _,step in ipairs(path) do nextpath[#nextpath+1]=step end
    visit(v.url,s+v.shift,nextpath)
   end
  end
  visit(x.url,0,{});table.sort(g.urls)
  local conflict=false
  for _,e in ipairs(edges) do if not e.confirmed and g.shifts[e.a] and g.shifts[e.b] and math.abs(g.shifts[e.b]-g.shifts[e.a]+e.drift)>(opts.tolerance or 2) then conflict=true end end
  if conflict then
   for _,u in ipairs(g.urls) do
    local single={id=u,root=u,urls={u},shifts={[u]=0},conflict=true}
    r.groups[#r.groups+1]=single;r.members[u]=single
   end
  else
   r.groups[#r.groups+1]=g
   for _,u in ipairs(g.urls) do r.members[u]=g;if g.shifts[u]~=0 then r.shifts[u]=g.shifts[u] end end
  end
 end end
 if #active>1 then r.baseline=active[1].url end
 for _,p in ipairs(r.pairs) do
  p.applied=p.reliable and r.members[p.a]==r.members[p.b] and math.abs(p.drift)>=0.001
  r.diag[#r.diag+1]=p
 end
 return r
end
-- Convert original source time into the group's stable relative coordinates.
function M.coordinate(result,url,raw)
 local g=result.members[url];if not g then return raw end
 local t=raw
 for _,step in ipairs(g.paths and g.paths[url] or {}) do
  local e=step.edge;local c=e.confirmed
  if c then
   local segments=c.segments or {{start=-math.huge,drift=c.before},{start=c.boundary,drift=c.after}}
   if not step.reverse then
    local found=nil
    for i,s in ipairs(segments) do
     local candidate=t-s.drift
     local finish=segments[i+1] and segments[i+1].start or math.huge
     if candidate>=(s.start or -math.huge) and candidate<finish then
      if found~=nil and math.abs(found-candidate)>0.001 then return nil end
      found=candidate
     end
    end
    if found==nil then return nil end;t=found
   else
    local drift=segments[1].drift
    for _,s in ipairs(segments) do if t>=s.start then drift=s.drift end end
    t=t+drift
   end
  else t=t+(step.reverse and e.drift or -e.drift) end
 end
 return t
end
return M
