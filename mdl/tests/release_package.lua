-- Exercises the actual resource paths and clean entry without a game process.
local loaded={};local env=setmetatable({},{__index=_G});env._G=env
local logs,wait_logs,files,rectangles,frames,clears=0,0,0,0,0,0
local segments,style
local values,registered={},{}
local objects={
 [555]={[18]={0,10,0},[29]={0,10,0},[44]=12,[45]=24,[49]=true,[52]=600,[56]=1},
 [600]={[44]={[8]={5,20,1}},[48]=1,[49]=1,[50]={5,20,1},[55]={5,20,1}}
}
local E={Application={build_identifier=function()return 'stingray:46805 437a3d445f9df7662b60086ac8ae3c65b5c95da6'end},
 Network={game_session=function()return 'session'end,peer_id=function()return 'me'end},
 GameSession={objects_owned_by=function()return {555}end,
 game_object_exists=function(_,id)return objects[id]~=nil end,
 game_object_field_batched=function(_,id)return objects[id]end},
 Gui={rect=function()rectangles=rectangles+1;error('debug HUD must not be loaded')end}}
env.stingray=E;env.io={open=function()files=files+1;error('no debug files')end}
env.ModOptionsMenu={api=1,register_option=function(id,spec)
 assert(spec.type=='choice'and spec.mod_id==ENTRY);registered[id]=spec
 if not values[id]then values[id]=spec.default end;return true
end,get=function(id)return values[id]end}
env.require=function(name)
 assert(name:sub(1,#BASE)==BASE,'unqualified dependency: '..name)
 if not loaded[name]then
  assert(SOURCES[name],'missing packaged resource: '..name)
  loaded[name]=setfenv(assert(loadstring(SOURCES[name],name)),env)()
 end
 return loaded[name]
end
loaded[BASE..'line_screen_renderer']={new=function(_,_,config)
 style=config.visual_style
 return {camera_model=true,draw=function(_,rows)segments=rows;frames=frames+1;return true end,
 clear=function()segments={};clears=clears+1 end}
end}
loaded[BASE..'line_observation_scope']={camera_origin=function()return {0,0,0}end,
 contains=function()return true end,valid_position=function(p)return type(p)=='table'and #p==3 end}
local addon=env.require(ENTRY)
assert(addon.name=='G60 锁定线'and addon.version==VERSION)
local cleanups={}
local ctx={settings={},log=function(message)
 if message:find('[G60] TARGET_WAIT ',1,true)then wait_logs=wait_logs+1
 else logs=logs+1 end
end,on_cleanup=function(cb)cleanups[#cleanups+1]=cb end}
addon.on_enable(ctx)
for i=1,100 do addon.on_update(ctx,.01)end
assert(frames>0 and segments[1].to[1]==5,'packaged addon failed to render native target')
assert(segments[1].end_marker.style=='cross_frame'and style.color_argb[2]==255)
assert(registered['g60_read_probe.target_shape'].choices[3]=='飞矛准星')
values['g60_read_probe.line_color']=2;values['g60_read_probe.target_shape']=3
addon.on_update(ctx,.01)
assert(style.color_argb[2]==255 and style.color_argb[3]==0 and style.target_marker.style=='spear_triangle')
objects[555][3]=true
for i=1,20 do addon.on_update(ctx,.01)end
assert(#segments==0,'packaged lifecycle retained ended source')
addon.on_disable();for _,cleanup in ipairs(cleanups)do cleanup()end
assert(logs==0 and files==0 and rectangles==0,'production build emitted debug output')
assert(wait_logs<=2,'target wait diagnostics spammed logs')
return {namespaced_entry_loaded=true,manager_mod_id_correct=true,native_target_drawn=true,
 default_white_frame=true,named_settings_live=true,terminal_cleanup=true,
 no_hud_rectangles=true,no_debug_file_writes=true,no_routine_debug_logs=true,
 bounded_target_wait_diagnostics=true}
