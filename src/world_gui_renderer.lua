-- World-space triangles use the scene GUI channel, bypassing debug LineObject.
-- API availability and actual full-viewport visibility remain separate evidence.
local Geometry=require('g60line.geometry')
local M={}
local function has(object,name) return type(object)=='table' and type(object[name])=='function' end
function M.new(engine,emit,config)
    config=config or {}
    local App,World,Gui,Matrix=engine.Application,engine.World,engine.Gui,engine.Matrix4x4
    local missing={}
    for _,item in ipairs({{App,'worlds'},{App,'main_world'},{World,'create_world_gui'},
        {World,'destroy_gui'},{Gui,'triangle'},{Gui,'reset'}}) do
        if not has(item[1],item[2]) then missing[#missing+1]=item[2] end
    end
    local vector_ok,vector=pcall(function() return engine.Vector3(0,0,0) end)
    local color_ok,color=pcall(function() return engine.Color(255,255,205,55) end)
    local matrix_ok,matrix=pcall(function() return Matrix.identity() end)
    if not vector_ok or vector==nil then missing[#missing+1]='Vector3';emit('Vector3_probe_failed '..tostring(vector)) end
    if not color_ok or color==nil then missing[#missing+1]='Color';emit('Color_probe_failed '..tostring(color)) end
    if not matrix_ok or matrix==nil then missing[#missing+1]='Matrix4x4.identity';emit('matrix_probe_failed '..tostring(matrix)) end
    emit('world_gui_api missing='..table.concat(missing,',')..' matrix_ok='..tostring(matrix_ok))
    if has(Gui,'resolution') then
        local ok,w,h=pcall(Gui.resolution)
        if ok then emit('viewport_resolution width='..tostring(w)..' height='..tostring(h)) end
    end
    local api={available=#missing==0,missing=table.concat(missing,','),count=0,triangles=0,kind='world_gui'}
    local world,gui
    local function live(worlds,wanted)
        if type(worlds)~='table' or wanted==nil then return false end
        for _,value in pairs(worlds) do if value==wanted then return true end end
        return false
    end
    local function release(worlds)
        local old_world,old_gui=world,gui
        world,gui,api.count,api.triangles=nil,nil,0,0
        if old_gui~=nil and live(worlds,old_world) then
            pcall(Gui.reset,old_gui)
            pcall(World.destroy_gui,old_world,old_gui)
        end
    end
    local function create(current)
        -- "immediate" is the documented lifecycle mode. The optional engine
        -- no_depth_test flag is requested only for diagnostics; reject/fallback
        -- is logged, and acceptance is not claimed as a visual confirmation.
        if config.disable_depth_test then
            local ok,value=pcall(World.create_world_gui,current,Matrix.identity(),1,1,'immediate','no_depth_test')
            if ok and value~=nil and value~=false then
                emit('world_gui_created immediate=true no_depth_test_request=accepted')
                return value
            end
            emit('world_gui_depth_flag_unavailable '..tostring(value))
        end
        local value=assert(World.create_world_gui(current,Matrix.identity(),1,1,'immediate'),'world GUI creation failed')
        emit('world_gui_created immediate=true depth=engine_default')
        return value
    end
    function api:draw(segments)
        if not self.available then return false,self.missing end
        local worlds,current=App.worlds(),App.main_world()
        if not live(worlds,current) then release(worlds);return false,'main_world_unavailable' end
        if world~=current then release(worlds) end
        if #segments==0 and gui==nil then return true end
        if gui==nil then gui=create(current);world=current end
        -- Reset only our own GUI; stale primitives cannot survive lost targets.
        Gui.reset(gui)
        self.triangles=0
        for _,segment in ipairs(segments) do
            local color=segment.reference and engine.Color(255,80,220,255)
                or segment.marker and engine.Color(255,255,255,255) or engine.Color(255,255,205,55)
            local width=segment.marker and 0.025 or (config.line_width or 0.04)
            for _,triangle in ipairs(Geometry.ribbon(segment,width)) do
                local a,b,c=triangle[1],triangle[2],triangle[3]
                Gui.triangle(gui,engine.Vector3(a[1],a[2],a[3]),engine.Vector3(b[1],b[2],b[3]),
                    engine.Vector3(c[1],c[2],c[3]),1,color)
                self.triangles=self.triangles+1
            end
        end
        self.count=#segments
        return true
    end
    function api:clear()
        if gui==nil then return end
        local ok,worlds=pcall(App.worlds)
        if ok then release(worlds) else world,gui,self.count,self.triangles=nil,nil,0,0 end
    end
    return api
end
return M
