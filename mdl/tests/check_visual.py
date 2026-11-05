"""Preset fidelity, live renderer changes and MDL setting callbacks."""
from pathlib import Path
import argparse,sys,json
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--deps',type=Path);args=p.parse_args()
if args.deps:sys.path.insert(0,str(args.deps.resolve()))
from lupa.lua51 import LuaRuntime
lua=LuaRuntime(unpack_returned_tuples=True)
lua.globals().SOURCES=lua.table_from({p.stem:p.read_text(encoding='utf8')for p in(ROOT/'g60_read_probe').glob('*.lua')})
result=lua.execute(r'''
local loaded={};local env=setmetatable({},{__index=_G});env._G=env
local E={Application={build_identifier=function()return 'test'end}}
env.stingray=E;env.io={open=function()return nil end}
env.require=function(name)
 if not loaded[name]then loaded[name]=setfenv(assert(loadstring(SOURCES[name])),env)()end;return loaded[name]
end
local Visual=env.require('probe_visual')
local visual=Visual.resolve();assert(visual.target_marker.style=='cross_frame'and visual.color_argb[2]==255)
for _,bad in ipairs({false,'blue',0,5,1.5,math.huge,0/0})do
 local v=Visual.resolve({line_color=bad,target_shape=bad})
 assert(v.target_marker.style=='cross_frame'and v.color_argb[3]==255)
end
local draw_rows,created,cleared,visual_ref=nil,0,0,nil
loaded.line_screen_renderer={new=function(_,_,config)
 created=created+1;visual_ref=config.visual_style
 return {camera_model=true,draw=function(_,rows)draw_rows=rows;return true end,
  clear=function()cleared=cleared+1 end}
end}
loaded.line_observation_scope={camera_origin=function()return {0,0,0}end,contains=function()return true end}
local lines=env.require('probe_lines').new(E,function()end)
local row={id=1,from={0,10,0},to={2,20,1}}
assert(lines.draw({row})=='DRAWING')
assert(draw_rows[1].end_marker.style=='cross_frame'and #draw_rows==1,'default frame missing')
for color=1,4 do for shape=1,3 do
 lines.set_settings({line_color=color,target_shape=shape});lines.draw({row})
 local current=Visual.resolve({line_color=color,target_shape=shape})
 assert(visual_ref.target_marker.style==current.target_marker.style)
 for i=1,4 do assert(visual_ref.color_argb[i]==current.color_argb[i])end
 if shape==2 then assert(#draw_rows==4 and not draw_rows[1].end_marker,'world cross missing')
 else assert(#draw_rows==1 and draw_rows[1].end_marker.style==current.target_marker.style)end
 assert(draw_rows[1].to==row.to,'preset moved target center')
end end
row.estimated=true;lines.draw({row});assert(draw_rows[1].estimated_marker.style=='ring','estimated ring lost')
assert(created==1 and cleared>0,'settings unnecessarily recreated renderer')
local changes,initial,stopped=nil,nil,false
loaded.probe_runtime={new=function(_,_,_,settings)
 initial=settings
 return {set_settings=function(s)changes=s end,shutdown=function()stopped=true end}
end}
local addon=env.require('mod');assert(#addon.options==2)
local ctx={settings={line_color=3,target_shape=3}}
addon.on_enable(ctx);assert(initial==ctx.settings,'saved selections not loaded')
addon.on_setting(ctx,'line_color',2);assert(changes.line_color==2 and changes.target_shape==3)
addon.on_setting(ctx,'target_shape',1);assert(changes.target_shape==1 and changes.line_color==2)
addon.on_disable();assert(stopped)
local Menu=env.require('probe_menu')
local definition={name='G60',options={Visual.options[1],Visual.options[2]}}
local specs,values={},{}
local api={api=1,register_option=function(id,spec)
 assert(spec.type=='choice'and spec.mod_id=='g60_read_probe')
 specs[id]=spec;if values[id]==nil then values[id]=spec.default end;return true
end,get=function(id)return values[id]end}
env.ModOptionsMenu=api
local saved={settings={line_color=3,target_shape=3}};local applied
local menu=Menu.new(definition,saved,function(v)applied={v.line_color,v.target_shape}end)
menu.update(0)
assert(#definition.options==0,'numeric fallback duplicated choice rows')
assert(values['g60_read_probe.line_color']==3 and values['g60_read_probe.target_shape']==3,'old numeric selections not migrated')
assert(specs['g60_read_probe.line_color'].choices[3]=='蓝色')
assert(specs['g60_read_probe.target_shape'].choices[3]=='飞矛准星')
-- Clicking the option cycles and wraps, while polling applies immediately.
values['g60_read_probe.line_color']=4;menu.update(.01);assert(applied[1]==4 and applied[2]==3)
values['g60_read_probe.line_color']=1;menu.update(.01);assert(applied[1]==1)
values['g60_read_probe.target_shape']=1;menu.update(.01);assert(applied[2]==1)
menu.stop();values['g60_read_probe.line_color']=2;menu.update(.01);assert(applied[1]==1,'disabled menu kept updating')
-- Re-enable with saved native choices, through the alternative MDL3 namespace.
env.ModOptionsMenu=nil;env.MDL3={mod_options_menu=api}
local restored=Menu.new(definition,{settings={}},function(v)applied={v.line_color,v.target_shape}end)
restored.update(0);assert(applied[1]==2 and applied[2]==1,'saved native choices not restored')
-- Missing provider restores original numeric rows, including after re-enable.
env.MDL3=nil;restored.update(.1);assert(#definition.options==2,'fallback rows lost after provider disappears')
restored.stop()
local unavailable=Menu.new(definition,{settings={}},function()end);unavailable.update(0)
assert(#definition.options==2)
-- Late provider availability replaces fallback rows without reloading the mod.
env.ModOptionsMenu=api;unavailable.update(.1);assert(#definition.options==0)
unavailable.stop()
return {named_choice_registration=true,old_numeric_migration=true,click_cycle_applies=true,
 native_saved_choices_restored=true,menu_provider_alias=true,no_duplicate_numeric_rows=true,
 provider_loss_and_late_load_supported=true,disabled_polling_stops=true,spear_name_updated=true,white_frame_default=true,all_twelve_combinations=true,live_render_update=true,
 invalid_selection_defaults=true,estimated_ring_preserved=true,endpoint_unchanged=true,
 mdl_saved_settings_loaded=true,mdl_callbacks_update_independently=true,runtime_verified=false}
''')
# Compare every preset field with the original project, not just our own definitions.
visual=lua.execute((ROOT/'g60_read_probe/probe_visual.lua').read_text(encoding='utf8'))
old=ROOT.parent/'config'
for i,name in enumerate(['white','red','blue','yellow'],1):
 v=visual.resolve(lua.table_from({'line_color':i}))[0]
 assert list(v.color_argb.values())==json.loads((old/'color'/f'{name}.json').read_text())['color_argb']
for i,name in enumerate(['cross_frame','cross','spear_triangle'],1):
 v=visual.resolve(lua.table_from({'target_shape':i}))[0]
 assert dict(v.target_marker.items())==json.loads((old/'target'/f'{name}.json').read_text())
report=dict(result.items());report['original_preset_parameters_match']=True
print(json.dumps(report,ensure_ascii=False,indent=2))
