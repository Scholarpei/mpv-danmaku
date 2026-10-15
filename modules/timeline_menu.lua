local utils=require('mp.utils')
local timeline=require('modules/timeline')
local M={}
local unpack=unpack or table.unpack
local pending,session,serial=nil,nil,0
local session_path
local function context()
 local path=mp.get_property('path')
 if session~=DANMAKU or session_path~=path then session=DANMAKU;session_path=path;serial=serial+1;pending=nil end
end
local function cmd(action,...)
 context();local v={'script-message-to',mp.get_script_name(),'timeline-ui',tostring(serial),action}
 for _,x in ipairs({...}) do v[#v+1]=tostring(x) end
 return v
end
local function row(title,action,... ) return {title=title,value=cmd(action,...)} end
local function note(title) return {title=title,selectable=false,keep_open=true} end
local function show(title,items)
 if uosc_available then
  mp.commandv('script-message-to','uosc','open-menu',utils.format_json({type='menu_timeline',title=title,items=items,footnote='正数推迟，负数提前；时长差仅供参考。使用 / 筛选'}))
 elseif input_loaded and type(open_menu_select)=='function' then open_menu_select(items)
 else show_message('没有可用的菜单框架',3) end
end
local function label(url)
 local s=DANMAKU.sources[url];return s and (s.provider or url) or url
end
local function fmt(t) return string.format('%02d:%05.2f',math.floor(t/60),t%60) end
local function entries(url)
 local s=DANMAKU.sources[url];local list={}
 for i,d in ipairs(s and s.data or {}) do list[#list+1]={index=i,raw=d.orig_time or d.time,text=d.text or ''} end
 table.sort(list,function(a,b) if a.raw~=b.raw then return a.raw<b.raw end return a.index<b.index end)
 return list
end
function M.pending() context();return pending end
function M.select(url,index)
 context();local result=timeline.prepare();local s=DANMAKU.sources[url];local d=s and s.data and s.data[index]
 if not d or s.blocked then return false end
 pending={session=DANMAKU,source=s,data=s.data,url=url,raw=d.orig_time or d.time,text=d.text,signature=result.signatures[url]}
 return true
end
function M.confirm(target,from)
 context();local p=pending
 if not p or p.session~=DANMAKU or DANMAKU.sources[p.url]~=p.source or p.source.data~=p.data then return false end
 if timeline.prepare().signatures[p.url]~=p.signature then pending=nil;return false end
 local ok=timeline.anchor(p.url,p.raw,target,'group',from and p.raw or nil)
 if ok then pending=nil end
 return ok
end
function M.adjust(url,delta,scope,from,frame)
 local raw=from and timeline.raw_at(url,frame or mp.get_property_number('time-pos',0)) or nil
 if from and not raw then show_message('此处没有唯一时间对应，请选一句原始弹幕作为分段起点',4);return false end
 return timeline.adjust(url,delta,scope,raw)
end
function M.build()
 context();local r=timeline.prepare();local items={}
 local related,independent,confirmed=0,0,0
 for _,g in ipairs(r.groups) do
  if #g.urls>1 then related=related+#g.urls else independent=independent+#g.urls end
  for _,u in ipairs(g.urls) do if DANMAKU.sources[u].timeline_local_status and DANMAKU.sources[u].timeline_local_status:find('已人工校准',1,true) then confirmed=confirmed+1 end end
 end
 local summary=note(string.format('源间：已关联 %d 个源 · 独立 %d 个源',related,independent))
 local local_summary=note(string.format('本地视频：已确认 %d 个源；未确认的源仍可正常播放',confirmed))
 for _,g in ipairs(r.groups) do for _,u in ipairs(g.urls) do
  local s=DANMAKU.sources[u]
  local current=mp.get_property_number('time-pos',0);local raw=timeline.raw_at(u,current)
  local delta=raw and current-raw or (r.shifts[u] or 0)
  local item=row(label(u),'source',u)
  item.hint=s.timeline_status..string.format(' · 第%d组 · 当前偏移 %+.2f秒', (function() for i,x in ipairs(r.groups) do if x==g then return i end end end)(),delta)
  items[#items+1]=item
 end end
 items[#items+1]=summary;items[#items+1]=local_summary
 if pending then items[#items+1]=row('继续校准：'..tostring(pending.text),'pending') end
 items[#items+1]=row('源间关联与分段分析','evidence')
 items[#items+1]=row('查看／删除已保存校准','operations')
 items[#items+1]=row('撤销最近一次校准操作','undo')
 items[#items+1]=row('清除本文件全部新校准','clear_all')
 if #r.groups==0 then table.insert(items,1,note('尚无可用弹幕源')) end
 return {items=items}
end
function M.open() show('时间轴校准',M.build().items) end
local function source_menu(url)
 local r=timeline.prepare();local s=DANMAKU.sources[url];if not s then return end
 local items={note(s.timeline_status or '待校准'),note(s.timeline_relation_detail or '尚无关联分析'),row('选一句原始弹幕，对照画面校准','browse',url)}
 if s.duration_seconds then
  local dur=mp.get_property_number('duration',0);local diff=s.duration_seconds-dur
  items[#items+1]=note(string.format('源时长 %.2f秒；与本地差 %+.2f秒（不等于延迟）',s.duration_seconds,diff))
  for other,source in pairs(DANMAKU.sources) do
   if other~=url and source.duration_seconds and math.abs(source.duration_seconds-s.duration_seconds)<=2 then
    items[#items+1]=note('时长接近 '..label(other)..'（疑似同版本，未据此关联）')
   end
  end
 end
 for _,scope in ipairs({'group','source'}) do
  local title=scope=='group' and '整组' or '仅此源'
  for _,from in ipairs({'all','from'}) do
   items[#items+1]=row(title..(from=='from' and '：从当前画面位置开始调整' or '：全片提前／推迟'),'adjust_menu',url,scope,from)
  end
 end
 items[#items+1]=row('清除此组本地校准（恢复相对对齐）','clear_group',url)
 items[#items+1]=row('清除此源手动微调（含旧延迟）','clear_source',url)
 show(label(url)..' · 校准',items)
end
local function browse(url)
 local items={};local list=entries(url)
 for _,e in ipairs(list) do
  local item=row(e.text,'pick',url,e.index)
  local mapped=timeline.map(url,e.raw)
  item.hint='原始 '..fmt(e.raw)..' → 当前 '..(mapped and fmt(mapped) or '无对应区段')
  items[#items+1]=item
 end
 show(label(url)..' · 选择与画面有关的一句（可搜索）',items)
end
local function pending_menu()
 if not M.pending() then return M.open() end
 local items={note(label(pending.url)..'：'..tostring(pending.text)),note('原始时间 '..fmt(pending.raw)),
  row('定位对应画面：关闭菜单后拖动／逐帧，再重新打开时间轴校准','locate'),
  row('确认当前画面时刻：校准整组全片','confirm','all'),
  row('确认当前画面时刻：仅从这句开始校准整组','confirm','from'),
  row('输入这句应出现的视频时间（秒）','target','all'),
  row('输入视频时间，仅从这句开始','target','from'),row('放弃本次选句','cancel')}
 show('确认弹幕与画面对应关系',items)
end
local function prompt(title,action,...)
 local args={...}
 if uosc_available then
  mp.commandv('script-message-to','uosc','open-menu',utils.format_json({type='menu_timeline_input',title=title,search_style='palette',search_debounce='submit',items={},on_search=cmd(action,unpack(args))}))
 elseif input_loaded then
  input.get({prompt=title..'：',submit=function(text)
   input.terminate();local v=cmd(action,unpack(args));v[#v+1]=text;mp.commandv(unpack(v))
  end})
 end
end
local function evidence()
 local r=timeline.prepare();local items={note('时长相差≤2秒仅表示疑似同版本，关联须由共同弹幕验证')}
 for _,chapter in ipairs(mp.get_property_native('chapter-list') or {}) do
  items[#items+1]=note('本地章节 '..fmt(chapter.time)..' · '..(chapter.title or '')..'（仅供定位，不代表源剪辑点）')
 end
 for i,p in ipairs(r.pairs) do
  local g=r.members[p.a];local same=g and g==r.members[p.b]
  items[#items+1]=note(label(p.a)..' ↔ '..label(p.b)..'：'..(same and '已关联' or ((r.members[p.a] and r.members[p.a].conflict) and '关联存在冲突，需复核' or p.reason)))
  items[#items+1]=note(string.format('独立文本 %d；重合 %.1f%%；偏移集中 %.1f%%；支持跨度 %.0f%%；候选偏移 %+.2f秒',p.independent,(p.overlap or 0)*100,(p.concentration or 0)*100,p.coverage*100,p.drift))
  if not p.reliable and p.failures then items[#items+1]=note('未关联依据：'..table.concat(p.failures,'；')) end
  for _,s in ipairs(p.segments or {}) do items[#items+1]=note(string.format('%s 原始 %s～%s：另一源晚 %+.2f秒',label(p.a),fmt(s.start),fmt(s.finish),s.drift)) end
  if p.segments and #p.segments>=2 then items[#items+1]=row('确认此处分段：输入 '..label(p.a)..' 原始时间轴的剪辑边界（秒，多个用逗号分隔）','boundary',i) end
 end
 if #r.pairs==0 then items[#items+1]=note('只有一个源，可直接选句校准到本地视频') end
 show('源间关联依据',items)
end
mp.register_script_message('open_timeline_calibration_menu',M.open)
mp.register_script_message('timeline-ui',function(token,action,a,b,c,d)
 context();if tostring(serial)~=token then return end
 if action=='source' then source_menu(a)
 elseif action=='browse' then browse(a)
 elseif action=='pick' then if M.select(a,tonumber(b)) then pending_menu() end
 elseif action=='pending' then pending_menu()
 elseif action=='locate' then mp.commandv('script-message-to','uosc','close-menu','menu_timeline');show_message('定位画面后，重新打开“时间轴校准”→“继续校准”',5)
 elseif action=='confirm' then
  if not M.confirm(mp.get_property_number('time-pos',0),a=='from') then show_message('校准失败，弹幕源或视频已改变',3) end;M.open()
 elseif action=='target' then prompt('输入目标视频时间（秒，可含小数）','target_value',a)
 elseif action=='target_value' then
  local n=tonumber(b);if n and n>=0 and n<math.huge and M.confirm(n,a=='from') then M.open() else show_message('请输入有效时间或重新选句',3) end
 elseif action=='adjust_menu' then
  local items={}
  for _,n in ipairs({-1,-0.5,0.5,1}) do items[#items+1]=row((n<0 and '提前 ' or '推迟 ')..math.abs(n)..'秒','adjust',a,b,c,n) end
  items[#items+1]=row('输入调整量（正数推迟，负数提前）','custom',a,b,c)
  show((b=='group' and '整组' or '仅此源')..(c=='from' and ' · 从当前画面开始' or ' · 全片'),items)
 elseif action=='custom' then prompt('调整秒数：正数推迟，负数提前','adjust',a,b,c)
 elseif action=='adjust' then
  local n=tonumber(d);if n and n==n and math.abs(n)<math.huge then M.adjust(a,n,b,c=='from');M.open() else show_message('请输入有效秒数',3) end
 elseif action=='evidence' then evidence()
 elseif action=='boundary' then prompt('输入第一个源原始时间轴的剪辑边界（秒，多个用逗号分隔）','boundary_value',a)
 elseif action=='boundary_value' then
  local boundaries={}
  for value in tostring(b or ''):gsub('，',','):gmatch('[^,%s]+') do boundaries[#boundaries+1]=tonumber(value) or false end
  if not timeline.confirm(tonumber(a),boundaries) then show_message('无法确认边界：请检查区段与源数据',4) end;M.open()
 elseif action=='undo' then timeline.undo();M.open()
 elseif action=='clear_group' then timeline.clear('group',a);M.open()
 elseif action=='clear_source' then timeline.clear_source(a);M.open()
 elseif action=='clear_all' then timeline.clear();M.open()
 elseif action=='cancel' then pending=nil;M.open()
 elseif action=='operations' then
  local items={};for i,op in ipairs(timeline.operations()) do
   local description=op.kind=='anchor' and ('画面锚点 '..fmt(op.raw)..' → '..fmt(op.target))
    or (op.kind=='relation' and ('确认分段关联 '..label(op.b))
    or (op.reset_legacy and '清除单源微调及旧延迟' or string.format('%s调整 %+.2f秒',op.scope=='group' and '整组' or '单源',op.delta or 0)))
   items[#items+1]=row(string.format('删除 #%d · %s · %s%s',i,label(op.source),description,op.start and (' · 从原始 '..fmt(op.start)) or ' · 全片'),'remove',i)
  end
  if #items==0 then items[1]=note('暂无新校准') end;show('已保存校准（选择一项删除）',items)
 elseif action=='remove' then timeline.remove(tonumber(a));M.open()
 end
end)
return M
