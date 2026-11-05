"""Large-scene mock comparison against the shipped 1.0.0 resource."""
from pathlib import Path
import argparse,sys,json,struct,zipfile,time,importlib.util
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--deps',type=Path);args=p.parse_args()
if args.deps:sys.path.insert(0,str(args.deps.resolve()))
from lupa.lua51 import LuaRuntime
spec=importlib.util.spec_from_file_location('release_builder',ROOT/'tools/build_release.py');builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)
old=(ROOT/'tests/fixtures/spatial_center_1_0_0.lua').read_text(encoding='utf8')

fixture=r'''
local E={Application={},World={},Unit={},Matrix4x4={}}
local units={};local calls,frame,peak,lists=0,0,0,0
local function hit()calls=calls+1;frame=frame+1 end
for i=1,15000 do units[i]={alive=true,animated=i>14945,meshes=(i<=11000 or i>14945)and 1 or 0,
 pos={(i%100)*8,math.floor(i/100)*8,0}}end
E.Application.main_world=function()hit();return 'w'end;E.Application.worlds=function()hit();return {'w'}end
E.World.units=function()hit();lists=lists+1;return units end
E.Unit.alive=function(u)hit();return u.alive end;E.Unit.world=function()hit();return 'w'end
E.Unit.num_meshes=function(u)hit();return u.meshes end
E.Unit.has_animation_state_machine=function(u)hit();return u.animated end
E.Unit.id=function()hit();return nil end
E.Unit.num_scene_graph_items=function()hit();return 2 end
E.Unit.world_position=function(u)hit();return u.pos end
E.Unit.box=function(u)hit();return {p={u.pos[1],u.pos[2],1}},{.5,.5,1}end
E.Matrix4x4.translation=function(p)hit();return p.p end
local loaded={};local env=setmetatable({},{__index=_G})
env.require=function(name)
 if not loaded[name]then loaded[name]=setfenv(assert(loadstring(SOURCES[name])),env)()end;return loaded[name]
end
local spatial=setfenv(assert(loadstring(CODE)),env)().new(E)
local now=0;local root=units[14990].pos
for i=1,1000 do now=now+1/60;frame=0;spatial.step(now,true);peak=math.max(peak,frame)end
for i=1,3 do now=now+.05;spatial.step(now,true);spatial.resolve(1,root)end
local query_before=spatial.stats and spatial.stats.queries or 0
calls=0;local list_before=lists
for i=1,300 do
 now=now+1/60;frame=0;spatial.step(now,true)
 if i%3==0 then local p=spatial.resolve(1,root);assert(p and p[3]==1)end
 peak=math.max(peak,frame)
end
local active_calls=calls
local stable_queries=spatial.stats and spatial.stats.queries-query_before or nil
calls=0;list_before=lists
for i=1,600 do now=now+1/60;spatial.step(now,false)end
local idle_calls,idle_lists=calls,lists-list_before
local resumed
if spatial.stats then
 units[15001]={alive=true,animated=true,meshes=1,pos={-200,-200,0}}
 local found=false
 for i=1,40 do
  now=now+1/60;spatial.step(now,true)
  local p=spatial.resolve(2,{-200,-200,0});if p then found=true;break end
 end
 assert(found,'idle resume did not discover a newly spawned target')
 resumed=found
end
return {active_engine_calls=active_calls,idle_engine_calls=idle_calls,idle_scene_lists=idle_lists,
 peak_engine_calls_per_step=peak,stable_binding_spatial_queries=stable_queries,new_target_after_idle=resumed}
'''
def run(code):
 lua=LuaRuntime(unpack_returned_tuples=True)
 lua.globals().SOURCES=lua.table_from({'probe_data':(ROOT/'g60_read_probe/probe_data.lua').read_text(encoding='utf8')})
 lua.globals().CODE=code
 start=time.perf_counter();r=dict(lua.execute(fixture).items());r['mock_wall_seconds']=round(time.perf_counter()-start,4)
 return r
before=run(old);after=run((ROOT/'g60_read_probe/probe_spatial_center.lua').read_text(encoding='utf8'))
assert after['idle_engine_calls']==0 and after['idle_scene_lists']==0
assert after['stable_binding_spatial_queries']==0
assert after['active_engine_calls']<before['active_engine_calls']*.4
assert after['peak_engine_calls_per_step']<before['peak_engine_calls_per_step']*.65
# Idle keeps enemy event metadata but must not query geometry or network positions.
lua=LuaRuntime(unpack_returned_tuples=True)
lua.globals().SOURCES=lua.table_from({p.stem:p.read_text(encoding='utf8')for p in(ROOT/'g60_read_probe').glob('*.lua')})
idle=lua.execute(r'''
local loaded={};local env=setmetatable({},{__index=_G});env._G=env
local ready,subscriptions,removed,geometry,named=0,0,0,0,0
local callbacks={}
env.HD2Data={ready=function()ready=ready+1;return true end,on=function(name,fn)
 subscriptions=subscriptions+1;callbacks[name]=fn
 return {unsubscribe=function()removed=removed+1 end}
end}
env.require=function(n)if not loaded[n]then loaded[n]=setfenv(assert(loadstring(SOURCES[n])),env)()end;return loaded[n]end
local center={forget_enemy=function()end,enemy_position=function()geometry=geometry+1;return {0,0,0}end}
local pool=env.require('probe_enemy_pool').new({GameSession={game_object_exists=function()return true end,
 game_object_field=function()named=named+1;return {1,0,0}end}},center)
for i=1,600 do pool.update(i/60,'s',false,1)end
assert(subscriptions==3 and geometry==0 and named==0,'idle pool queried positions')
callbacks.entity_spawned({enemy=true,entity_id=100,network_id=100,mission=1})
pool.update(10.1,'s',true,1);assert(subscriptions==3)
assert(#pool.snapshot(10.1)==1 and named==1,'idle observation was not retained or refreshed')
for i=1,64 do callbacks.entity_spawned({enemy=true,entity_id=i,position={i,0,0},mission=1})end
for i=1,60 do pool.update(10.1+i/60,'s',true,1)end
assert(pool.stats.max_records_per_update<=8,'candidate geometry work not distributed')
for i=1,120 do pool.update(11.1+i/60,'s',false,1)end
assert(removed==0,'idle discarded enemy observations')
local old_geometry,old_named=geometry,named
for i=1,600 do pool.update(13.1+i/60,'s',false,1)end
assert(geometry==old_geometry and named==old_named,'idle resumed expensive pool work')
pool.shutdown();assert(removed==3,'shutdown retained subscriptions')
return true
''')
report={'scene_units':15000,'baseline_1_0_0':before,'optimized':after,
 'active_engine_calls_reduction_percent':round((1-after['active_engine_calls']/before['active_engine_calls'])*100,1),
 'idle_pool_geometry_stopped_metadata_retained':bool(idle),'runtime_verified':False}
print(json.dumps(report,ensure_ascii=False,indent=2))
