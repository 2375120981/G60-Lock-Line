"""Necessary new-path checks only: inference, fresh targets, outer ring and isolation."""
import ctypes,json,struct,sys
from zipfile import ZipFile
from build import ROOT,VERSION,MODULES
from lua_runtime import lua_library

def main():
    continuity_only='--continuity-only' in sys.argv
    with ZipFile(ROOT/'release'/('G60-Lock-Line-V'+VERSION+'.zip')) as z:
        body=z.read('Core/9ba626afa44a3aa3.patch_0');entry=struct.unpack_from('<7Q6I',body,104)
        core=body[entry[2]+8:entry[2]+entry[7]]
        assert len(z.namelist())==40 and not any(n.startswith('Source/') for n in z.namelist())
        baseline=ROOT/'release/G60-Lock-Line-V1.1.1.zip'
        appearance_compared=baseline.is_file()
        if appearance_compared:
            with ZipFile(baseline) as old:
                for name in z.namelist():
                    if name.startswith(('Target/','Color/','Glow/','Previews/')) or name=='Cover.png':assert z.read(name)==old.read(name)
    dll=ctypes.CDLL(lua_library())
    dll.luaL_newstate.restype=ctypes.c_void_p
    dll.luaL_openlibs.argtypes=[ctypes.c_void_p]
    dll.luaL_loadbuffer.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_size_t,ctypes.c_char_p]
    dll.lua_pcall.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int]
    dll.lua_tolstring.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.POINTER(ctypes.c_size_t)]
    dll.lua_tolstring.restype=ctypes.c_void_p
    dll.lua_settop.argtypes=[ctypes.c_void_p,ctypes.c_int]
    dll.lua_close.argtypes=[ctypes.c_void_p]
    state=dll.luaL_newstate();assert state
    def run(name,text,execute=False):
        if isinstance(text,str):text=text.encode()
        dll.lua_settop(state,0)
        result=dll.luaL_loadbuffer(state,text,len(text),name.encode())
        if not result and execute:result=dll.lua_pcall(state,0,0,0)
        if result:
            length=ctypes.c_size_t();ptr=dll.lua_tolstring(state,-1,ctypes.byref(length))
            raise AssertionError(name+': '+ctypes.string_at(ptr,length.value).decode('utf-8','replace'))
    def module(name,alias):
        source=(ROOT/'src'/(name+'.lua')).read_text(encoding='utf-8')
        for dependency,replacement in MODULES:source=source.replace("require('g60line."+dependency+"')",replacement)
        return 'local '+alias+'=(function()\n'+source+'\nend)()\n'
    prefix=module('observation_scope','ObservationScope')+module('marker_shapes','MarkerShapes')+module('target_estimator','TargetEstimator')
    from build import lua
    config=lua(json.loads((ROOT/'config/estimation.json').read_text()))
    fixture=prefix+'local options='+config+r'''
local target={id=100,key='enemy-generation',resource='enemy',point={100,0,0},alive=true,priority=.1}
local remote={id=2,network=2,key='remote-flight',entity_key='remote-generation',state=0,behavior=4,
 remote_active=true,locally_owned=false,remote_phase=4,flag=0,target_id=0,explosive_ready=true,
 from={0,0,0},reason='explosive_alive'}
local estimate=TargetEstimator.new(options)
local chosen,reason
chosen,reason=estimate:choose(remote,{target},0,0)
assert(chosen==target and reason=='uncertain_collecting_motion','initial uncertainty shows a live candidate immediately')
for i=0,8 do remote.from={i,0,0};chosen,reason=estimate:choose(remote,{target},i*.1,i*.1) end
assert(chosen and chosen.id==100 and reason=='estimated','forward pursuit ranks the target')
-- A second collinear enemy makes the intent ambiguous; keep the displayed guess.
local rival={id=101,key='other-enemy',resource='enemy',point={120,0,0},alive=true,priority=.1}
remote.from={9,0,0};chosen,reason=estimate:choose(remote,{target,rival},.9,.9)
assert(chosen==target and reason=='uncertain_ambiguous','ambiguous scene retains the previous estimate')
remote.remote_phase=3;chosen,reason=estimate:choose(remote,{target},1,1)
assert(chosen==target and reason=='uncertain_searching','search phase retains the estimate')
remote.remote_phase=4;remote.locally_owned=true
assert(not estimate:choose(remote,{target},1.1,1.1),'owned G60 never uses inference')
remote.locally_owned=false;estimate:reset()
for i=0,8 do remote.from={i,0,0};chosen=estimate:choose(remote,{target},2+i*.1,2+i*.1) end
assert(chosen)
remote.from={9,0,0};chosen,reason=estimate:choose(remote,{target},2.9,2.4)
assert(chosen and chosen.id==100 and reason=='uncertain_stale_candidates','stale pool retains identity for fresh endpoint validation')
estimate:reset()
for i=0,8 do
 remote.from={20*math.cos(i*.5),20*math.sin(i*.5),0}
 chosen=estimate:choose(remote,{target},4+i*.1,4+i*.1)
end
assert(chosen and chosen.id==100,'circling movement retains an uncertain estimate')
remote.terminal=true;assert(not estimate:choose(remote,{target},5,5));remote.terminal=false
estimate:reset()
for i=0,8 do
 remote.from={i,0,0}
 local escaping={id=102,key='escaping',resource='enemy',point={100+i,0,0},alive=true,priority=.1}
 chosen,reason=estimate:choose(remote,{escaping},6+i*.11,6+i*.11)
end
assert(chosen and chosen.id==102 and reason=='uncertain_no_candidate','unconfirmed closing speed retains the guessed enemy')
-- A strong new candidate must settle before switching; no blank line meanwhile.
estimate:reset()
local behind={id=103,key='behind',point={-2,0,0},alive=true}
local ahead={id=104,key='ahead',point={100,0,0},alive=true}
for i=0,2 do
 remote.from={i,0,0};chosen,reason=estimate:choose(remote,{behind,ahead},8+i*.11,8+i*.11)
 assert(chosen.id==103,'initial nearest estimate persists while collecting')
end
local pending
remote.from={3,0,0};chosen,reason,_,pending=estimate:choose(remote,{behind,ahead},8.33,8.33)
assert(chosen.id==103 and reason=='uncertain_confirming' and pending.id==104,'old line remains while confirming a new candidate')
for i=4,8 do remote.from={i,0,0};chosen=estimate:choose(remote,{behind,ahead},8+i*.11,8+i*.11) end
assert(chosen.id==104,'stable strong candidate eventually replaces the initial guess')
chosen=estimate:choose(remote,{},9,8.1)
assert(chosen.id==104,'empty stale pool does not erase the retained identity')
estimate:reset();assert(not estimate:choose(remote,{},10,10),'without live candidates there is no invented target')
local dead={id=105,key='dead',point={1,0,0},alive=false}
local far={id=106,key='far',point={400,0,0},alive=true}
assert(not estimate:choose(remote,{dead,far},10.1,10.1),'initial fallback excludes dead and out-of-range candidates')
remote.remote_phase=1;assert(not estimate:choose(remote,{target},10.2,10.2),'held stage never estimates')
remote.remote_phase=4
-- Search/orbit never supplies a strong lock, but fresh estimates still switch.
estimate:reset();remote.remote_phase=3;remote.from={0,0,0}
local left={id=107,key='left',point={20,0,0},alive=true}
local right={id=108,key='right',point={80,0,0},alive=true}
chosen=estimate:choose(remote,{left,right},11,11);assert(chosen.id==107)
right.point={10,0,0}
for i=1,4 do
 chosen,reason=estimate:choose(remote,{left,right},11+i*.11,11+i*.11)
 assert(chosen,'search-phase re-estimation never blanks the line')
 if i==1 then assert(chosen.id==107 and reason=='uncertain_confirming') end
end
assert(chosen.id==108 and reason=='uncertain_searching','uncertain search updates the selected enemy')
left.point={3,0,0}
for i=5,8 do chosen=estimate:choose(remote,{left,right},11+i*.11,11+i*.11);assert(chosen) end
assert(chosen.id==107,'continuous re-estimation can switch back when scene changes again')
-- Nearly equal pursuit scores remain ambiguous, yet the better guess updates.
estimate:reset();remote.remote_phase=4
local a={id=109,key='a',point={100,0,0},alive=true}
local b={id=110,key='b',point={120,0,0},alive=true}
for i=0,4 do remote.from={i,0,0};chosen=estimate:choose(remote,{a,b},13+i*.11,13+i*.11);assert(chosen.id==109) end
a.point={120,0,0};b.point={100,0,0}
for i=5,10 do remote.from={i,0,0};chosen,reason=estimate:choose(remote,{a,b},13+i*.11,13+i*.11);assert(chosen) end
assert(chosen.id==110 and reason=='uncertain_ambiguous','ambiguous pursuit continually re-ranks candidates')
-- Close candidates alternate too quickly to switch; display remains stable.
estimate:reset();remote.remote_phase=3;remote.from={0,0,0}
left.point={20,0,0};right.point={30,0,0}
assert(estimate:choose(remote,{left,right},15,15).id==107)
for i=1,10 do
 right.point={i%2==0 and 30 or 10,0,0}
 chosen=estimate:choose(remote,{left,right},15+i*.11,15+i*.11)
 assert(chosen.id==107,'rapidly alternating estimates do not flicker between targets')
end
remote.remote_phase=4
-- The distinguishing circle surrounds the square corners for every style.
for _,style in ipairs({'world_cross','cross_frame','spear_triangle'}) do
 local ring=MarkerShapes.estimated_ring({style=style,width_px=1.5,half_size_px=20})
 assert(ring.radius_px==32 and ring.radius_px>20*math.sqrt(2) and ring.segments==64)
 local strokes=MarkerShapes.screen(ring,{0,0});assert(#strokes==64)
 for _,s in ipairs(strokes)do for _,p in ipairs({s.from,s.to})do
  assert(math.abs(math.sqrt(p[1]^2+p[2]^2)-32)<1e-8)
 end end
end
'''+module('controller','Controller')+r'''
local mine={id=1,network=1,key='own',entity_key='own',state=4,behavior=4,flag=1,target_id=99,
 target_key='real-target',to={20,0,0},from={0,0,0},eligible=true,explosive_ready=true,reason='selected',locally_owned=true}
remote.from={0,0,0};remote.eligible=false
local rows={mine,remote};local draw,light={},{}
local refresh=true;local endpoint_valid=true
local endpoint_height=1;local preferred_ids={}
local pool={target}
local reader={sample=function()
 return {mission=true,ids={1,2},rows=rows,enemies=refresh and pool or nil}
end,estimated_endpoint=function(self,id,key)
 local enemy=id==target.id and target or rival
 assert(id==enemy.id and key==enemy.key)
 if not endpoint_valid then return nil end
 return {id=id,key=key,point={enemy.point[1]+.5,0,endpoint_height},resource='enemy',alive=true,endpoint_kind='body'}
end,set_prediction_targets=function(self,values)preferred_ids=values end}
local renderer={draw=function(self,segments)draw=segments;self.count=#segments;return true end,
 clear=function()draw={} end}
local glow={sync=function(self,values)light=values end,clear=function()light={} end}
local config={observation_mode='nearby_active',tracking_radius_m=80,estimation=options,endpoint_marker=true,
 visual_style={target_marker={style='cross_frame',half_size_px=20},g60_marker={style='ring',radius_px=6}},
 glow={enabled=true,offset_z_m=.3}}
local host=Controller.new(reader,renderer,nil,function()end,config,glow,function()return {0,0,0}end)
-- Each sample returns a new row, as the real observer does.
local function tick(i)
 remote.to=nil;remote.target_id=0;remote.estimated=nil;remote.target_key=nil
 remote.from={i,0,0};host:tick(.11)
end
for i=0,8 do tick(i) end
assert(#draw==2 and draw[1].end_marker.style=='cross_frame' and draw[1].estimated_marker==nil,'own real lock unchanged')
assert(draw[2].estimated_marker.radius_px==32 and draw[2].end_marker.style=='cross_frame')
assert(draw[2].to[3]==1,'estimated endpoint comes from fresh target pose')
assert(#light==2 and light[2].locked,'estimated pursuit light and own real lock coexist')
pool={target,rival};tick(9)
assert(remote.estimate_reason=='uncertain_ambiguous' and draw[2].estimated_marker.radius_px==32,'uncertain line keeps its distinguishing circle')
remote.remote_phase=3;tick(10)
assert(draw[2].estimated_marker and draw[2].to[3]==1,'search phase keeps a freshly read target with its circle')
rival.point={30,0,0};endpoint_height=2
tick(11)
assert(draw[2].estimated_marker and #preferred_ids==2 and preferred_ids[1]==100 and preferred_ids[2]==101,'visible and pending estimates both get fresh candidate reads')
for i=12,15 do tick(i);assert(draw[2].estimated_marker,'re-estimation retains outer circle throughout the switch') end
assert(remote.target_id==101 and draw[2].to[1]==30.5 and draw[2].to[3]==2,'controller renders newly estimated identity at fresh coordinates')
refresh=false
endpoint_height=3
for i=16,20 do tick(i) end
assert(remote.estimate_reason=='uncertain_stale_candidates' and draw[2].estimated_marker and draw[2].to[3]==3,'stale candidate pool still validates current target pose')
endpoint_valid=false;tick(9)
assert(#draw==2 and draw[2].start_marker and draw[2].estimated_marker==nil and draw[2].from==draw[2].to)
assert(#light==2 and not light[2].locked,'dead/reused target drops line immediately but retains G60 position')
remote.terminal=true;tick(10)
assert(#draw==1 and #light==1,'G60 explosion clears prediction immediately')
remote.terminal=false;endpoint_valid=true;tick(11)
assert(#draw==1 and #light==1,'terminal generation cannot be revived by a new estimate')
host:stop()
'''
    native_fixture=module('layout','Layout')+module('observation_scope','ObservationScope')+r'''
local dead_tag,dead_state,reused,changed=0,0,false,false
local identity=string.rep('a',24)
local function word(value)
 local s={};for i=1,4 do s[i]=string.char(value%256);value=math.floor(value/256) end
 return table.concat(s)
end
local TargetData={new=function(reader,base,exe)
 return {base=base,entity=function(id)return {id=id,handle=15,address=0x90000,
  identity=reused and string.rep('b',24) or identity,resource='enemy'}end,
 ptr=function(a)
  local addresses={[base+0x3326430]=0x10000,[0x10038]=0x11000,
   [base+0x3326688]=0x20000,[0x21048]=0x22000,[0x22000]=0x90000,[0x21058]=0x23000}
  return assert(addresses[a],string.format('unexpected pointer %x',a))
 end,
 hash=function(a,id)assert(a==0x10018 or a==0x21030);return 0 end,
 read=function(a,n)
  if a==0x11000 then assert(n==8);return word(dead_tag)..word(0) end
  assert(a==0x90000 and n==24);return reused and string.rep('b',24) or identity
 end,
 u32=function(a)assert(a==0x2319c);return dead_state end,
 unit_position=function()return {100,0,1},'body' end,
 validate=function()return not changed end}
end}
'''+module('replication_probe','ReplicationProbe')+module('enemy_reader','EnemyReader')+r'''
local replica={state=4,behavior=4,index=2,total=3,entity_flags=2,from={1,2,3}}
assert(ReplicationProbe.remote_active(replica,false,true,false),'native exclusion flags do not hide a live remote')
assert(not ReplicationProbe.remote_active(replica,true,true,false),'owned native state is preserved')
assert(not ReplicationProbe.remote_active(replica,nil,true,false),'unknown ownership does not infer')
assert(not ReplicationProbe.remote_active(replica,false,true,true),'terminal remote never revives')
replica.state=0;assert(not ReplicationProbe.remote_active(replica,false,true,false));replica.state=4
replica.index=3;assert(not ReplicationProbe.remote_active(replica,false,true,false));replica.index=2
replica.from=nil;assert(not ReplicationProbe.remote_active(replica,false,true,false))
local config={estimation_enemies={enemy={priority=.1}},pose_getters={},
 estimation={enemy_read_limit=1,candidate_radius_m=200}}
local key=identity:sub(1,20)
assert(EnemyReader.one(nil,0x100000,0,1,key,config).alive)
dead_tag=2^25;assert(EnemyReader.one(nil,0x100000,0,1,key,config)==nil);dead_tag=0
dead_state=2;assert(EnemyReader.one(nil,0x100000,0,1,key,config)==nil);dead_state=0
reused=true;assert(EnemyReader.one(nil,0x100000,0,1,key,config)==nil);reused=false
changed=true;assert(not pcall(EnemyReader.one,nil,0x100000,0,1,key,config));changed=false
local rows,next_cursor,stats=EnemyReader.capture(nil,0x100000,0,{1,2,3},{{0,0,0}},config,1,{3})
assert(#rows==1 and rows[1].id==3 and stats.checked==1,'pending target stays in bounded refresh')
'''
    render_fixture=module('projection','Projection')+module('marker_shapes','MarkerShapes')+r'''
local main,ui={},{}
local model={camera={},position={0,0,0},forward={0,1,0},near=.1}
local CameraSelector={new=function()return {sample=function()return model end,reset=function()end}end}
local triangles={}
local V3=setmetatable({x=function(p)return p[1]end,y=function(p)return p[2]end,z=function(p)return p[3]end},
 {__call=function(_,x,y,z)return {x,y,z}end})
local engine={Vector3=V3,Vector2=function(x,y)return {x,y}end,Color=function(a,r,g,b)return {a,r,g,b}end,
 Application={worlds=function()return {main,ui}end,main_world=function()return main end},
 World={create_screen_gui=function()return {}end,destroy_gui=function()end,units=function()return {}end,
  debug_camera_pose=function()return {}end},
 Unit={alive=function()return true end,num_cameras=function()return 1 end,camera=function()return model.camera end},
 Camera={world_pose=function()return {}end,near_range=function()return .1 end,
  world_to_screen=function(camera,p)return V3(480+p[1]*40,270+p[3]*40,0)end},
 Matrix4x4={translation=function()return {}end,x=function()end,y=function()end,z=function()end},
 Gui={reset=function()triangles={}end,resolution=function()return 960,540 end,rect=function()end,
  triangle=function(gui,a,b,c,layer,color)triangles[#triangles+1]={a,b,c,color=color}end}}
'''+module('screen_renderer','ScreenRenderer')+r'''
for _,style in ipairs({'world_cross','cross_frame','spear_triangle'})do
 local spec={style=style,half_size_m=1,half_size_px=20,width_px=1.5}
 local config={visual_style={target_marker=spec,color_argb={255,0,128,255}}}
 local renderer=ScreenRenderer.new(engine,function()end,config)
 local segment={from={0,10,0},to={5,10,0},end_marker=MarkerShapes.is_screen(spec) and spec or nil}
 local segments={segment}
 for _,s in ipairs(MarkerShapes.world(spec,segment.to))do segments[#segments+1]=s end
 assert(renderer:draw(segments));local base=#triangles
 segment.estimated_marker=MarkerShapes.estimated_ring(spec)
 assert(renderer:draw(segments));assert(#triangles-base==128,'circle submitted for '..style)
 -- The ring is emitted on the main segment before world-cross strokes.
 local ring_start=2+(MarkerShapes.is_screen(spec) and #MarkerShapes.screen(spec,{0,0})*2 or 0)+1
 local maxradius=0
 for i=ring_start,ring_start+127 do
  local triangle=triangles[i];assert(triangle.color[1]==255 and triangle.color[2]==0 and triangle.color[3]==128)
  for _,p in ipairs(triangle)do maxradius=math.max(maxradius,math.sqrt((p[1]-680)^2+(p[3]-270)^2))end
 end
 if style=='world_cross' then assert(maxradius>43 and maxradius<44,'near world cross remains enclosed')
 else assert(maxradius>32 and maxradius<33,'32 pixel ring with 1.5 pixel stroke') end
end
'''
    try:
        dll.luaL_openlibs(state)
        run('packaged-core-syntax',core)
        run('estimator-controller-ring',fixture,True)
        if not continuity_only:
            run('enemy-reader-validity-and-budget',native_fixture,True)
            run('estimated-ring-screen-submission',render_fixture,True)
    finally:dll.lua_close(state)
    report={'version':VERSION,'packaged_lua_syntax':'passed','uncertain_estimate_continuity_and_switching':'passed',
        'search_and_ambiguous_estimates_continuously_update':'passed','alternating_candidates_do_not_flicker':'passed',
        'visible_and_pending_candidates_prioritized':'passed','new_target_identity_and_fresh_coordinates_rendered':'passed',
        'owned_G60_keeps_native_target':'passed','fresh_target_and_terminal_cleanup':'passed',
        'enemy_death_and_identity_read_guards':'not_repeated' if continuity_only else 'passed',
        'preferred_candidate_read_budget':'not_repeated' if continuity_only else 'passed',
        'estimated_outer_circle_radius_px':32,'all_three_styles':'passed',
        'screen_submission_color_and_near_world_cross_enclosure':'not_repeated' if continuity_only else 'passed',
        'minimal_distribution_files':40,'appearance_resources_unchanged':True if appearance_compared else 'baseline_not_available',
        'game_launched':False,'native_observer_executed':False,'ingame_verified':False}
    (ROOT/'build/estimation-check.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
