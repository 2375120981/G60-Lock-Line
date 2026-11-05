-- G60 Lock Line; MDL-managed lifecycle.
local VERSION='1.0.2'
local Runtime=require('probe_runtime')
local Visual=require('probe_visual')
local Menu=require('probe_menu')
local Definition
local state
local function log(tag,message)
    if state and state.ctx.log and (tag=='ERROR'or tag=='TARGET_WAIT')then
        pcall(state.ctx.log,'[G60] '..tag..' '..tostring(message))
    end
end
local function stop()
    if not state or not state.active then return end
    state.active=false
    if state.settings then state.settings.stop()end
    if state.runtime then state.runtime.shutdown()end
end
Definition={
    name='G60 锁定线',version=VERSION,author='2375120981',
    menu_id='mods/2375120981/g60_lock_line/main',
    description='显示G60锁定连线与目标标记，支持队友目标估算、配色和准星形状设置。',
    options={Visual.options[1],Visual.options[2]},
    on_enable=function(ctx)
        stop()
        state={ctx=ctx or{},active=true}
        local current=state
        local E=rawget(_G,'stingray')or{}
        local build
        if type((E.Application or{}).build_identifier)=='function'then
            local ok,value=pcall(E.Application.build_identifier);if ok then build=value end
        end
        state.runtime=Runtime.new(E,log,build,state.ctx.settings)
        state.settings=Menu.new(Definition,state.ctx,function(values)
            if state==current and state.active then state.runtime.set_settings(values)end
        end,log)
        state.settings.update(0)
        if type(state.ctx.on_cleanup)=='function'then
            state.ctx.on_cleanup(function()if state==current then stop()end end)
        end
    end,
    on_update=function(_,dt)
        if not state or not state.active then return end
        local ok,why=pcall(function()
            local step=type(dt)=='number'and dt==dt and dt>0 and dt<2 and dt or 1/60
            state.settings.update(step);state.runtime.update(step)
        end)
        if not ok then log('ERROR',why);stop()end
    end,
    on_setting=function(ctx,key,value)
        if key~='line_color'and key~='target_shape'then return end
        if not state or not state.active then return end
        local context=type(ctx)=='table'and ctx or state.ctx
        context.settings=type(context.settings)=='table'and context.settings or{}
        context.settings[key]=value;state.runtime.set_settings(context.settings)
    end,
    on_disable=stop
}
return Definition
