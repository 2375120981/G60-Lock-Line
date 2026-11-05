"""Referenced target fallback, recovery and cold-cache regression checks."""
import argparse,json,sys
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--deps',type=Path);args=p.parse_args()
if args.deps:sys.path.insert(0,str(args.deps.resolve()))
from lupa.lua51 import LuaRuntime
root=Path(__file__).resolve().parents[1]
lua=LuaRuntime(unpack_returned_tuples=True)
lua.globals().SOURCES=lua.table_from({p.stem:p.read_text(encoding='utf8')for p in(root/'g60_read_probe').glob('*.lua')})
result=lua.execute(r'''
local E={Network={},GameSession={}}
local env=setmetatable({stingray=E},{__index=_G});env._G=env
local loaded,rows,events={},nil,{}
env.require=function(n)
 if not loaded[n]then loaded[n]=setfenv(assert(loadstring(SOURCES[n])),env)()end
 return loaded[n]
end
loaded.probe_lines={new=function()return {
 draw=function(r)rows=r;return 'OK',#r end,clear=function()end,
 shutdown=function()end,set_settings=function()end}end}
local owned,objects={},{}
local named_ok,batch_kind,x=false,'nil',3
local batches,peak,named,wrong_named=0,0,0,0
E.Network.game_session=function()return 's'end
E.Network.peer_id=function()return 'me'end
E.GameSession.objects_owned_by=function()return owned end
E.GameSession.game_object_exists=function(_,id)return objects[id]~=nil end
E.GameSession.game_object_field_batched=function(_,id)
 batches=batches+1
 if id==200 then
  if batch_kind=='error'then error('unavailable')end
  if batch_kind=='unsupported'then return {[1]=9}end
  return nil
 end
 return objects[id]
end
E.GameSession.game_object_field=function(_,id,field)
 named=named+1;if id~=200 then wrong_named=wrong_named+1 end
 assert(field=='position')
 if id==200 and named_ok then return {x,20,1}end
end
local runtime=env.require('probe_runtime').new(E,function(k,v)
 if k=='TARGET_WAIT'then events[#events+1]=v end
end,'stingray:46805 437a3d445f9df7662b60086ac8ae3c65b5c95da6')
local function step(n)
 for i=1,n do batches=0;runtime.update(.01);peak=math.max(peak,batches)end
end
step(100)
-- Local source references an enemy outside its owned list, with a cold center cache.
owned={300,301};objects[301]={[1]=9}
objects[300]={[18]={0,10,0},[29]={0,10.1,0},[44]=12,[45]=24,[49]=true,[52]=200,[56]=1}
objects[200]={}
named_ok=true;step(80)
assert(#rows==1 and rows[1].locally_owned and rows[1].to[1]==3)
assert(rows[1].centered==false,'cold center prevented network fallback')
x=8;step(20);assert(rows[1].to[1]==8,'named position stopped refreshing')
batch_kind='unsupported';x=9;step(20);assert(rows[1].to[1]==9)
batch_kind='error';x=10;step(20);assert(rows[1].to[1]==10)
named_ok=false;batch_kind='nil';step(30)
assert(rows[1].from and not rows[1].to,'missing data reused stale target')
local n=#events;step(40);assert(#events==n,'unchanged wait reason spammed logs')
assert(events[n]:find('BATCH_UNAVAILABLE',1,true),'missing target reason absent')
named_ok=true;x=12;step(20);assert(rows[1].to[1]==12,'target failed to recover')
assert(wrong_named==0 and named>0,'named reads escaped explicit target references')
assert(peak<=2,'batch read budget exceeded')
runtime.shutdown()
return {fallback=true,moving_target=true,unsupported_layout=true,batch_error=true,
 recovery=true,wait_log_deduplicated=true,max_batches_per_frame=peak}
''')
print(json.dumps(dict(result.items()),ensure_ascii=False,indent=2))
