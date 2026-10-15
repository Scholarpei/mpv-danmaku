local path=debug.getinfo(1,"S").source:sub(2)
local dir=path:match("^(.*)[/\\]") or "."
local root=dir:match("^(.*)[/\\]") or "."
package.path=root.."/?.lua;"..package.path
local utils=require("mp.utils")
require("modules/utils")
local f=assert(io.open(root.."/main.lua","rb"));local main=f:read("*all"):gsub("\r\n","\n");f:close()
local chunk=assert(main:match("(function update_source_duration_history.-)\nlocal function get_save_danmaku_output"))
local loader=assert(loadstring("local utils=require('mp.utils')\n"..chunk))
setfenv(loader,getfenv(1))
loader()
local failures=0
local function check(name,ok) print((ok and "PASS " or "FAIL ")..name);if not ok then failures=failures+1 end end
HISTORY_PATH="memory"
local current="movie.mkv"
mp.get_property=function(name) if name=="path" then return current end end
local history={show_danmaku=true}
read_file=function() return utils.format_json(history) end
write_json_file=function(_,data) history=data end
DANMAKU={sources={}}
local s={from="user_custom",duration_seconds=1445,anime_title="test",blocked=true}
add_source_to_history("source-url",s)
DANMAKU.sources={}
read_danmaku_source_record(current)
check("source duration survives history round trip",DANMAKU.sources["source-url"].duration_seconds==1445)
check("history retains source settings",DANMAKU.sources["source-url"].blocked)
update_source_duration_history("source-url",1450)
check("metadata refresh updates existing association",history[current].sources["source-url"].duration_seconds==1450)
update_source_duration_history("missing-url",999)
check("metadata refresh does not create association",history[current].sources["missing-url"]==nil)
history[current].sources["legacy-url"]={from="user_custom"}
DANMAKU.sources={};read_danmaku_source_record(current)
check("legacy record without duration loads",DANMAKU.sources["legacy-url"].duration_seconds==nil)
if failures>0 then os.exit(1) end print("ALL PASS");os.exit(0)
