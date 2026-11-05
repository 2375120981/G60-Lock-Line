local ScreenRenderer=require('line_screen_renderer')
local MarkerShapes=require('line_marker_shapes')
local Scope=require('line_observation_scope')
local Visual=require('probe_visual')
local M={}
local function call(fn,...)
    if type(fn)~='function' then return nil end
    local ok,a,b=pcall(fn,...);if ok then return a,b end
end
function M.new(E,emit,settings)
    local R={};local renderer
    local last_status
    local visual,visual_key=Visual.resolve(settings)
    local function status(s)
        if s~=last_status then last_status=s;emit('LINE_STATE',s) end
    end
    function R.clear()
        if renderer then pcall(renderer.clear,renderer) end
    end
    function R.shutdown() R.clear();renderer=nil end
    function R.set_settings(values)
        local next_visual,key=Visual.resolve(values)
        if key==visual_key then return end
        visual_key=key
        visual.color_argb=next_visual.color_argb
        visual.target_marker=next_visual.target_marker
        R.clear();emit('VISUAL_PRESET',key)
    end
    function R.draw(rows)
        if E.Window and call(E.Window.show_cursor)==true then R.clear();return 'MENU',0 end
        if #rows==0 then R.clear();return 'WAIT_G60',0 end
        local origin_ok,origin=pcall(Scope.camera_origin,E)
        if not origin_ok or not origin then R.clear();status('WAIT_CAMERA');return 'WAIT_CAMERA',0 end
        if not renderer then
            local ok,value=pcall(ScreenRenderer.new,E,function(s)emit('LINE_RENDER',s)end,{visual_style=visual})
            if not ok then status('RENDERER_ERROR '..tostring(value));return 'RENDERER_ERROR',0 end
            renderer=value
        end
        local segments,links={},0
        for _,r in ipairs(rows) do
            if r.from and Scope.contains(origin,r.from,80) then
                local to=r.to or r.from
                segments[#segments+1]={from=r.from,to=to,start_marker=visual.g60_marker,
                    end_marker=r.to and MarkerShapes.is_screen(visual.target_marker)and visual.target_marker or nil,
                    estimated_marker=r.estimated and {style='ring',radius_px=32,width_px=1.5,segments=64}or nil}
                if r.to then
                    links=links+1
                    for _,s in ipairs(MarkerShapes.world(visual.target_marker,r.to))do segments[#segments+1]=s end
                end
            end
        end
        local ok,drawn,why=pcall(renderer.draw,renderer,segments)
        if not ok or not drawn then
            R.clear();status('DRAW_FAILED '..tostring(why or drawn));return 'RENDERER_ERROR',0
        end
        if not renderer.camera_model then status('WAIT_CAMERA');return 'WAIT_CAMERA',0 end
        status(links>0 and 'DRAWING' or 'WAIT_TARGET_POSITION')
        return links>0 and 'DRAWING' or 'WAIT_TARGET_POSITION',links
    end
    return R
end
return M
