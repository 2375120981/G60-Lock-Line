-- MDL's ModOptionsMenu API 1: named choices cycle on click.
-- Poll values instead of retaining callbacks after disable/hot reload.
local M={}
local saved_fallbacks=setmetatable({},{__mode="k"})
local definitions={
 {key='line_color',id='g60_read_probe.line_color',label='线条颜色',
  choices={'白色','红色','蓝色','黄色'},description='点击循环切换：白色、红色、蓝色、黄色；应用于连线和标记。'},
 {key='target_shape',id='g60_read_probe.target_shape',label='锁定标记形状',
  choices={'方框十字','十字','飞矛准星'},description='点击循环切换旧版标记预设；默认方框十字，估算圆环保留。'}
}
local function call(fn,...)
 if type(fn)~='function'then return nil end
 local ok,value=pcall(fn,...);if ok then return value end
end
local function provider()
 local menu=rawget(_G,'ModOptionsMenu')
 local mdl=rawget(_G,'MDL3')
 local compat=type(mdl)=='table'and(mdl.mod_options_menu or mdl.mod_options)
 for _,api in ipairs({menu or false,compat or false})do
  if type(api)=='table'and tonumber(api.api)==1 and type(api.register_option)=='function'
   and type(api.get)=='function'then return api end
 end
end
local function valid(v,count)return type(v)=='number'and v==math.floor(v)and v>=1 and v<=count end
function M.new(definition,ctx,apply,emit)
 local fallback=saved_fallbacks[definition]
 if not fallback then
  fallback={};for _,v in ipairs(definition.options)do fallback[#fallback+1]=v end
  saved_fallbacks[definition]=fallback
 end
 ctx.settings=type(ctx.settings)=='table'and ctx.settings or{}
 local R={};local api,registered,next_try,clock,stopped=nil,{},0,0,false
 local signature=nil
 local function refresh_rows()
  for i=#definition.options,1,-1 do definition.options[i]=nil end
  for _,option in ipairs(fallback)do
   if not registered[option.key]then definition.options[#definition.options+1]=option end
  end
 end
 function R.update(dt)
  if stopped then return end
  clock=clock+(dt or 0)
  local current=provider()
  if current~=api then api=current;registered={};next_try=0;refresh_rows()end
  if api and clock>=next_try then
   next_try=clock+.5
   for _,spec in ipairs(definitions)do
    if not registered[spec.key]then
     local initial=ctx.settings[spec.key]
     local ok=call(api.register_option,spec.id,{type='choice',mod=definition.name,mod_id=definition.menu_id or 'g60_read_probe',
      label=spec.label,choices=spec.choices,description=spec.description,
      default=valid(initial,#spec.choices)and initial or 1})
     if ok==true then registered[spec.key]=true end
    end
   end
   refresh_rows()
  end
  if api then
   for _,spec in ipairs(definitions)do
    if registered[spec.key]then
     local value=call(api.get,spec.id)
     if valid(value,#spec.choices)then ctx.settings[spec.key]=value end
    end
   end
  end
  local key=tostring(ctx.settings.line_color)..'/'..tostring(ctx.settings.target_shape)
  if key~=signature then signature=key;apply(ctx.settings)end
  local mode=tostring(registered.line_color==true)..'/'..tostring(registered.target_shape==true)
  if mode~=R.mode then
   R.mode=mode;if emit then emit('VISUAL_MENU','choice_registered='..mode)end
  end
 end
 function R.stop()stopped=true;api=nil end
 return R
end
return M
