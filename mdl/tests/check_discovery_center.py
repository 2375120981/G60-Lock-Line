"""Burst discovery and unambiguous spatial-center checks without the game."""
from pathlib import Path
import argparse,sys,json
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--deps',type=Path);args=p.parse_args()
if args.deps:sys.path.insert(0,str(args.deps.resolve()))
from lupa.lua51 import LuaRuntime
lua=LuaRuntime(unpack_returned_tuples=True)
lua.globals().SOURCES=lua.table_from({p.stem:p.read_text(encoding='utf8')for p in (ROOT/'g60_read_probe').glob('*.lua')})
result=lua.execute(r'''
local E={Application={},World={},Unit={},Matrix4x4={}}
local world='world';local units={};local boxes=0
for i=1,200 do units[i]={id=i,alive=true,animated=false,meshes=1,pos={1000+i,0,0}}end
units[88].animated=false;units[88].pos={10,0,0}
units[89].animated=true;units[89].pos={20,0,0}
units[90].pos={1000,0,0};units[90].animated=false
E.Application.main_world=function()return world end;E.Application.worlds=function()return {world}end
E.World.units=function()return units end
E.Unit.alive=function(u)return u.alive end;E.Unit.id=function(u)return 0 end
E.Unit.world=function()return world end;E.Unit.has_animation_state_machine=function(u)return u.animated end
E.Unit.num_meshes=function(u)return u.meshes end
E.Unit.num_scene_graph_items=function()return 2 end
E.Unit.world_position=function(u,node)
 assert(node==0 or node==1)
 if u==units[88]and node==0 then return {10,0,-5}end
 return u.pos
end
E.Unit.box=function(u,ignore)assert(ignore==true);boxes=boxes+1;return {p={u.pos[1],u.pos[2],u.pos[3]+(u.height or 1.7)}},{.5,.5,1.7}end
E.Matrix4x4.translation=function(p)return p.p end
local loaded={};local env=setmetatable({},{__index=_G})
env.require=function(name)
 if not loaded[name]then loaded[name]=setfenv(assert(loadstring(SOURCES[name])),env)()end;return loaded[name]
end
local s=env.require('probe_spatial_center').new(E)
for i=1,10 do s.step(i*.01)end
local p,why=s.resolve(7,{10,0,0});assert(p==nil and why=='SPATIAL_CONFIRMING')
s.step(.15);p,why=s.resolve(7,{10,0,0});assert(p==nil and why=='SPATIAL_CONFIRMING')
s.step(.20);p,why=s.resolve(7,{10,0,0})
assert(p and p[3]==1.7 and why=='UNIT_SPATIAL_BOX_CENTER','unique spatial center failed')
units[89].pos={10.1,0,0};s.step(.21)
local before=boxes;p,why=s.resolve(7,{10,0,0})
assert(p and p[3]==1.7 and why=='UNIT_SPATIAL_BOX_CENTER','overlap caused fallback')
-- A nearly exact root and a clearly farther nearby model are distinguishable.
units[89].pos={10.25,0,0};s.step(.22)
assert(s.resolve(7,{10,0,0}))
s.step(.27);assert(s.resolve(7,{10,0,0}))
s.step(.32);p,why=s.resolve(7,{10,0,0})
assert(p and p[3]==1.7,'tight unique root rejected because another mesh is within .4m')
units[89].pos={20,0,0};units[88].alive=false;s.step(.33)
assert(s.resolve(7,{10,0,0})==nil,'dead unit still bound')
s.reset();assert(s.resolve(7,{10,0,0})==nil,'reset retained mapping')
-- A mesh without an ID past the old 512 entry cap must remain eligible.
for i=1,700 do units[i]={id=i,alive=true,animated=false,meshes=1,pos={1000+i,0,0}}end
units[650].pos={30,0,0};E.Unit.id=function()return nil end
for i=1,20 do s.step(1+i*.01)end
assert(s.resolve(8,{30,0,0})==nil)
s.step(1.25);assert(s.resolve(8,{30,0,0})==nil)
s.step(1.30);p,why=s.resolve(8,{30,0,0})
assert(p and p[1]==30 and why=='UNIT_SPATIAL_BOX_CENTER','large no-ID cache failed')
s.reset()
-- Animation roots stay fresh while a large scenery cache is busy refreshing.
for i=1,1200 do units[i]={id=i,alive=true,animated=false,meshes=1,pos={1000+i,0,0}}end
units[1149].animated=true;units[1150].animated=true;units[1150].pos={50,0,0}
for i=1,40 do s.step(2+i*.01)end
units[1150].pos={90,0,0};s.step(2.41)
local p,why=s.resolve(9,{90,0,0});assert(why=='SPATIAL_CONFIRMING','moving animated root remained stale')
s.step(2.46);s.resolve(9,{90,0,0})
s.step(2.51);p,why=s.resolve(9,{90,0,0});assert(p and p[1]==90)
-- Two exact overlapping roots keep the already established visual center.
units[1149].pos={90,0,0};units[1149].height=3
for i=1,15 do s.step(2.51+i*.01)end
p,why=s.resolve(9,{90,0,0});assert(p and p[1]==90 and p[3]==1.7 and why=='UNIT_SPATIAL_BOX_CENTER','overlap replaced stable model')
s.reset()
-- Many overlapping roots use a bounded nearest shortlist, not a fallback.
units={}
for i=1,65 do units[i]={id=i,alive=true,animated=false,meshes=1,pos={30+i*.001,0,0}}end
for i=1,4 do s.step(6+i*.01)end
s.resolve(10,{30,0,0});s.step(6.09);s.resolve(10,{30,0,0})
s.step(6.14);p,why=s.resolve(10,{30,0,0})
assert(p and math.abs(p[1]-30.001)<.00001 and why=='UNIT_SPATIAL_BOX_CENTER','crowded roots caused fallback')
s.reset()
-- A baseline backlog + 100 new ordinary objects must not delay a new G60.
local objects,owned={},{}
local reads,by_id,rows=0,{},{}
local now,peak,frame=0,0,0
E={Application={},Network={},GameSession={}}
E.Network.game_session=function()return 'session'end;E.Network.peer_id=function()return 'me'end
E.GameSession.objects_owned_by=function()return owned end
E.GameSession.game_object_exists=function(_,id)return objects[id]~=nil end
E.GameSession.game_object_field_batched=function(_,id)
 reads=reads+1;frame=frame+1;by_id[id]=(by_id[id]or 0)+1;return objects[id]
end
env=setmetatable({stingray=E},{__index=_G});env._G=env;loaded={}
env.require=function(name)
 if not loaded[name]then loaded[name]=setfenv(assert(loadstring(SOURCES[name])),env)()end;return loaded[name]
end
loaded.probe_lines={new=function()return {draw=function(r)rows=r;return 'OK',0 end,clear=function()end,shutdown=function()end}end}
loaded.probe_hud={new=function()return {draw=function()end,clear=function()end,shutdown=function()end}end}
local r=env.require('probe_runtime').new(E,function()end,'stingray:46805 437a3d445f9df7662b60086ac8ae3c65b5c95da6')
local function step(n)
 for _=1,n do now=now+.01;frame=0;r.update(.01);peak=math.max(peak,frame)end
end
for i=1,350 do owned[#owned+1]=i;objects[i]={[1]=i}end
step(100)
for i=400,499 do owned[#owned+1]=i;objects[i]={[1]=i}end
objects[700]={[18]={0,10,0},[29]={0,10,0},[44]=12,[45]=24,[49]=false,[52]=32767,[56]=0}
owned[#owned+1]=700
local start=now;local detected
for _=1,25 do step(1);for _,row in ipairs(rows)do if row.id==700 then detected=now-start;break end end;if detected then break end end
assert(detected and detected<=.25,'burst discovery was starved')
for _=1,200 do
 step(1);local found=false;for _,row in ipairs(rows)do if row.id==700 then found=true end end
 assert(found,'new-object burst starved an already tracked G60')
end
for i=400,499 do assert((by_id[i]or 0)<=3,'ordinary new object was repeatedly polled')end
assert(peak<=2,'native per-frame bound exceeded')
r.shutdown()
return {spatial_center_unique_match=true,three_sample_confirmation=true,overlap_keeps_center=true,
 nearby_model_does_not_force_fallback=true,crowded_nearest_shortlist=true,animated_refresh_with_large_scenery=true,overlap_after_binding_preserved=true,
 non_animated_mesh_supported=true,duplicate_unit_ids_supported=true,node1_root_supported=true,
 no_id_mesh_beyond_512_supported=true,dead_match_removed=true,spatial_reset=true,
 discovery_under_burst_seconds=detected,ordinary_objects_max_attempts=3,native_batches_per_frame_max=peak,
 runtime_verified=false}
''')
print(json.dumps(dict(result.items()),ensure_ascii=False,indent=2))
