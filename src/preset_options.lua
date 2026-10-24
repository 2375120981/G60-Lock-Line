-- Selected manager presets are ordinary Lua resources, not BSL addons.
-- Loading them synchronously avoids addon ordering and cross-addon globals.
local M={}
function M.apply(visual,load,emit)
    local function selected(name,validate)
        local ok,value=pcall(load,'mods/c09nat/g60_lock_line_'..name)
        if ok and validate(value) then emit('preset_'..name..'=loaded');return value end
        emit('preset_'..name..'=default reason='..(ok and 'invalid_preset' or tostring(value)))
    end
    local target=selected('target',function(value)
        if type(value)~='table' or type(value.width_px)~='number'
            or not (value.width_px>0 and value.width_px<=32) then return false end
        if value.style=='world_cross' then
            return type(value.half_size_m)=='number' and value.half_size_m>0 and value.half_size_m<=10
        elseif value.style=='cross_frame' then
            return type(value.half_size_px)=='number' and value.half_size_px>0 and value.half_size_px<=512
                and type(value.gap_px)=='number' and value.gap_px>=0 and value.gap_px<value.half_size_px
        elseif value.style=='spear_triangle' then
            return type(value.half_size_px)=='number' and value.half_size_px>0 and value.half_size_px<=512
                and type(value.corner_radius_px)=='number' and value.corner_radius_px>=0
                and value.corner_radius_px<=value.half_size_px
        end
        return false
    end)
    if target then visual.target_marker=target end
    local color=selected('color',function(value)
        if type(value)~='table' or type(value.color_argb)~='table' or #value.color_argb~=4 then return false end
        for i=1,4 do
            local channel=value.color_argb[i]
            if type(channel)~='number' or not (channel>=0 and channel<=255) then return false end
        end
        return true
    end)
    if color then visual.color_argb=color.color_argb end
    return visual
end
function M.glow(load,emit)
    local ok,value=pcall(load,'mods/c09nat/g60_lock_line_glow')
    local function color(v)
        if type(v)~='table' or #v~=4 then return false end
        for i=1,4 do if type(v[i])~='number' or not (v[i]>=0 and v[i]<=255) then return false end end
        return true
    end
    local function range(v,a,b) return type(v)=='number' and v>=a and v<=b end
    if ok and type(value)=='table' then
        if value.enabled==true and value.mode=='native_bloom_white_red'
            and value.unit_resource=='units/c09nat/g60_status_light'
            and value.marker_resource=='units/c09nat/g60_bloom_marker'
            and value.unlocked_material=='materials/c09nat/g60_bloom_white'
            and value.locked_material=='materials/c09nat/g60_bloom_red'
            and range(value.marker_radius_m,0.02,1)
            and color(value.unlocked_argb) and color(value.locked_argb)
            and range(value.intensity,0.1,64) and range(value.radius_m,0.2,10)
            and range(value.offset_z_m,-1,1) and range(value.point_radius_px,2,32) then
            emit('preset_glow=native_bloom_white_red');return value
        end
    end
    emit('preset_glow=off reason='..(ok and 'invalid_preset' or 'not_selected_or_unavailable'))
    return {enabled=false}
end
return M
