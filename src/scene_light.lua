-- Own cosmetic light Units only. Never mutate the G60 Unit or its materials.
local M={}
local function has(object,name) return type(object)=='table' and type(object[name])=='function' end
function M.new(engine,emit,spec)
    spec=spec or {enabled=false}
    local api={enabled=spec.enabled==true,count=0}
    if not api.enabled then
        function api:sync() return true end
        function api:clear() end
        return api
    end
    local App,World,Unit,Light=engine.Application,engine.World,engine.Unit,engine.Light
    local missing={}
    for _,item in ipairs({{App,'worlds'},{App,'main_world'},{World,'spawn_unit'},
        {World,'destroy_unit'},{World,'update_unit'},{Unit,'alive'},{Unit,'node'},
        {Unit,'set_local_position'},{Unit,'num_lights'},{Unit,'light'},
        {Light,'set_color'},{Light,'set_intensity'},{Light,'set_enabled'},
        {Light,'set_casts_shadows'},{Light,'set_falloff_start'},{Light,'set_falloff_end'}}) do
        if not has(item[1],item[2]) then missing[#missing+1]=item[2] end
    end
    api.available=#missing==0
    emit('glow_light_api available='..tostring(api.available)..' missing='..table.concat(missing,','))
    local world,units,failed_world=nil,{},nil
    local function live(worlds,wanted)
        for _,value in pairs(worlds or {}) do if value==wanted then return true end end
        return false
    end
    local function destroy(entry,worlds)
        if entry and live(worlds,world) then
            local ok,alive=pcall(Unit.alive,entry.unit)
            if ok and alive then
                pcall(function() Light.set_enabled(Unit.light(entry.unit,1),false) end)
                local destroyed,why=pcall(World.destroy_unit,world,entry.unit)
                if not destroyed then emit('glow_destroy_error '..tostring(why)) end
            end
        end
    end
    local function clear(worlds)
        for _,entry in pairs(units) do destroy(entry,worlds) end
        units,api.count={},0
    end
    function api:clear()
        if not self.available then return end
        local ok,worlds=pcall(App.worlds)
        clear(ok and worlds or {})
    end
    function api:sync(rows)
        if not self.available then return false,'light_api_unavailable' end
        local worlds,main=App.worlds(),App.main_world()
        if not live(worlds,main) then clear(worlds);world=nil;return false,'main_world_unavailable' end
        if world~=main then clear(worlds);world=main;failed_world=nil end
        if failed_world==main then return false,'light_backend_disabled' end
        local seen={}
        for _,row in ipairs(rows) do seen[row.key]=true end
        for key,entry in pairs(units) do
            if not seen[key] then destroy(entry,worlds);units[key]=nil end
        end
        for _,row in ipairs(rows) do
            local entry=units[row.key]
            local position=engine.Vector3(row.from[1],row.from[2],row.from[3])
            local ok,why=pcall(function()
                if entry and not Unit.alive(entry.unit) then units[row.key]=nil;entry=nil end
                if not entry then
                    local unit=assert(World.spawn_unit(main,spec.unit_resource,position),'light Unit spawn failed')
                    entry={unit=unit};units[row.key]=entry
                    assert(Unit.num_lights(unit)==1,'status light Unit must contain one light')
                    entry.node=Unit.node(unit,'root')
                    local light=Unit.light(unit,1)
                    Light.set_enabled(light,true);Light.set_casts_shadows(light,false)
                    Light.set_intensity(light,spec.intensity)
                    Light.set_falloff_start(light,0.1);Light.set_falloff_end(light,spec.radius_m)
                    emit('glow_light_created id='..tostring(row.id)..' resource='..spec.unit_resource)
                end
                Unit.set_local_position(entry.unit,entry.node,position)
                World.update_unit(main,entry.unit)
                if entry.locked~=row.locked then
                    local argb=row.locked and spec.locked_argb or spec.unlocked_argb
                    -- Light colors are linear RGB [0,1], not GUI ARGB [0,255].
                    Light.set_color(Unit.light(entry.unit,1),engine.Vector3(argb[2]/255,argb[3]/255,argb[4]/255))
                    entry.locked=row.locked
                    emit('glow_state id='..tostring(row.id)..' locked='..tostring(row.locked))
                end
            end)
            if not ok then
                emit('glow_light_error '..tostring(why));clear(worlds);failed_world=main
                return false,tostring(why)
            end
        end
        self.count=0;for _ in pairs(units) do self.count=self.count+1 end
        return true
    end
    return api
end
return M
