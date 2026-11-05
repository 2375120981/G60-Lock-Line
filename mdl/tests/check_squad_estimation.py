"""Offline squad ownership, estimated selection, lifecycle and native budget."""
from pathlib import Path
import argparse,sys,json
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--deps',type=Path);args=p.parse_args()
if args.deps:sys.path.insert(0,str(args.deps.resolve()))
from lupa.lua51 import LuaRuntime
lua=LuaRuntime(unpack_returned_tuples=True)
lua.globals().SOURCES=lua.table_from({p.stem:p.read_text(encoding='utf8')for p in(ROOT/'g60_read_probe').glob('*.lua')})
result=lua.execute(r'''
local E={Application={},Network={},GameSession={},World={},Unit={},Matrix4x4={}}
local now,session,peers=0,'one',{'me','team'}
local local_ids,remote_ids={400},{401}
local objects,rows,events,logs={},{},{},{}
local frame,peak,unsubscribed=0,0,0
local enemy={alive=true,pos={20,0,0}}
local units={enemy}
local function grenade(x,target)return {[18]={x,0,0},[29]={x,0,0},[44]=12,[45]=24,[49]=true,[52]=target or 32767,[56]=1}end
local function target(x)return {[44]={[8]={x,0,0}},[48]=1,[49]=1,[50]={x,0,0},[55]={x,0,0}}end
objects[400]=grenade(0,900);objects[401]=grenade(1);objects[900]=target(20);objects[901]=target(30)
E.Network.game_session=function()return session end;E.Network.peer_id=function()return 'me'end
E.Network.connections=function()return peers end
E.GameSession.peers=function()return peers end
E.GameSession.objects_owned_by=function(_,peer)if peer=='me'then return local_ids else return remote_ids end end
E.GameSession.game_object_exists=function(_,id)return objects[id]~=nil end
E.GameSession.game_object_field_batched=function(_,id)frame=frame+1;return objects[id]end
E.Application.main_world=function()return 'world'end;E.Application.worlds=function()return {'world'}end
E.World.units=function()return units end
E.Unit.alive=function(u)return u.alive end;E.Unit.world=function()return 'world'end
E.Unit.num_meshes=function()return 1 end;E.Unit.num_scene_graph_items=function()return 2 end
E.Unit.has_animation_state_machine=function()return true end;E.Unit.world_position=function(u)return u.pos end
E.Unit.box=function(u)return {p={u.pos[1],u.pos[2],u.pos[3]+1}},{1,1,1}end
E.Matrix4x4.translation=function(m)return m.p end
local loaded={};local env=setmetatable({stingray=E},{__index=_G});env._G=env
local epoch=1
local D={ready=function()return true end,mission=function()return {epoch=epoch,in_mission=true}end}
D.on=function(name,fn)
 events[name]=fn
 return {unsubscribe=function()events[name]=nil;unsubscribed=unsubscribed+1 end}
end
env.HD2Data=D
env.require=function(name)
 if not loaded[name]then loaded[name]=setfenv(assert(loadstring(SOURCES[name])),env)()end;return loaded[name]
end
loaded.probe_lines={new=function()return {draw=function(r)rows=r;return 'DRAWING',#r end,clear=function()rows={}end,shutdown=function()rows={}end}end}
loaded.probe_hud={new=function()return {draw=function()end,clear=function()end,shutdown=function()end}end}
local runtime=env.require('probe_runtime').new(E,function(tag,msg)logs[#logs+1]=tag..' '..tostring(msg) end,env.require('probe_data').BUILD)
local function step(n)
 for _=1,n do now=now+.01;frame=0
  if objects[401]then local x=1+now*2;objects[401][18]={x,0,0};objects[401][29]={x,0,0}end
  runtime.update(.01);peak=math.max(peak,frame)
 end
end
local function row(id)for _,r in ipairs(rows)do if r.id==id then return r end end end
step(130)
assert(row(400)and row(400).to and not row(400).estimated,'local native lock regressed')
assert(row(401)and row(401).locally_owned==false and row(401).estimated,'remote estimate unavailable from confirmed target pool')
assert(row(401).to[1]==20 and row(401).to[3]==1)
-- A readable remote target always wins over the estimate.
objects[401][52]=901;step(45)
assert(row(401).target==901 and not row(401).estimated and row(401).to[1]==30,'native remote target did not override estimate')
-- Known Hub enemies bind by event position and follow current mesh coordinates.
objects[400][52]=32767;objects[401][52]=32767
local valid=true
local handle={position=function()return {20,0,0}end,is_valid=function()return valid end}
events.entity_spawned({event='entity_spawned',enemy=true,entity_id=800,network_id=900,entity=handle,mission=1})
step(60);enemy.pos={23,0,0};objects[900]=target(23);step(30)
assert(row(401).estimated and row(401).to[1]==23,'enemy endpoint did not follow model')
-- Transfer source authority from local to teammate without losing it.
local_ids={};remote_ids={400,401};step(45)
assert(row(400)and row(400).locally_owned==false,'ownership transfer lost source')
objects[400][3]=true;step(25);assert(not row(400),'terminal remote G60 remained visible')
-- Death removes the guess even while the corpse Unit and network object remain.
events.entity_died({enemy=true,entity_id=800,network_id=900,mission=1});valid=false
objects[901]=nil;step(230)
assert(row(401)and not row(401).to,'dead or stale estimate remained visible')
-- Peer departure and session switch clear old sources.
peers={'me'};step(40);assert(not row(401),'departed teammate remained visible')
session='two';objects={};local_ids={};remote_ids={};epoch=2;step(40);assert(#rows==0)
runtime.shutdown();assert(unsubscribed==3,'Hub subscriptions leaked on disable')
assert(peak<=2,'native field budget increased')
-- The port retains trajectory scoring and confirms switches without a blank line.
local estimate=env.require('probe_estimator').new(env.require('probe_config').estimation)
local pool={{key='ahead',id=1,alive=true,point={30,0,0}},
 {key='side',id=2,alive=true,point={0,4,0}}}
local function choose(t,x)return estimate:choose({key=7,from={x,0,0},remote_active=true,locally_owned=false},pool,t,t)end
local first=choose(0,0);assert(first.key=='side')
local changing=choose(.1,1);assert(changing.key=='side','switch confirmation skipped')
choose(.2,2);choose(.3,3)
local chosen=choose(.5,5);assert(chosen.key=='ahead','flight direction did not beat proximity')
local local_guess=estimate:choose({key=8,from={0,0,0},remote_active=true,locally_owned=true},pool,.6,.6)
assert(local_guess==nil,'local G60 entered estimated path')
local fail=false
local isolated=env.require('probe_squad').new({Network={},GameSession={
 peers=function()return {'me','team'}end,
 objects_owned_by=function()if fail then error('temporary failure')end;return {701}end}})
assert(isolated.scan('s','me',0)[701]=='team')
fail=true;assert(isolated.scan('s','me',.3)[701]=='team','transient query discarded peer')
assert(isolated.scan('s','me',.9)[701]==nil,'failed peer cache never expired')
return {peer_query_failure_has_bounded_grace=true,trajectory_score_and_switch_confirmation=true,local_never_estimated=true,remote_discovery=true,ownership_transfer=true,remote_native_precedence=true,
 estimated_model_follows_motion=true,local_native_preserved=true,death_removes_guess=true,
 peer_departure_clears=true,session_and_epoch_clear=true,subscriptions_cleaned=true,
 native_batches_per_frame_max=peak,runtime_verified=false}
''')
print(json.dumps(dict(result.items()),ensure_ascii=False,indent=2))
