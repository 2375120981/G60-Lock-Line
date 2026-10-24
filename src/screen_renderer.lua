-- Project with the matched live camera, then clip against the entire actual
-- screen. Draw on a screen GUI in the UI World, outside the world-GUI channel.
local Projection=require('g60line.projection')
local CameraSelector=require('g60line.camera_selector')
local MarkerShapes=require('g60line.marker_shapes')
local M={}
local function has(object,name) return type(object)=='table' and type(object[name])=='function' end
function M.new(engine,emit,config)
    config=config or {}
    local visual=config.visual_style or {}
    local App,World,Gui,Unit,Camera,Matrix,V3=engine.Application,engine.World,engine.Gui,engine.Unit,engine.Camera,engine.Matrix4x4,engine.Vector3
    local missing={}
    for _,item in ipairs({{App,'worlds'},{App,'main_world'},
        {World,'create_screen_gui'},{World,'destroy_gui'},{Gui,'triangle'},{Gui,'rect'},{Gui,'reset'},{Gui,'resolution'}}) do
        if not has(item[1],item[2]) then missing[#missing+1]=item[2] end
    end
    local camera_missing={}
    for _,item in ipairs({{World,'units'},{World,'debug_camera_pose'},
        {Unit,'alive'},{Unit,'num_cameras'},{Unit,'camera'},{Camera,'world_pose'},{Camera,'near_range'},{Camera,'world_to_screen'},
        {Matrix,'translation'},{Matrix,'x'},{Matrix,'y'},{Matrix,'z'},{V3,'x'},{V3,'y'},{V3,'z'}}) do
        if not has(item[1],item[2]) then camera_missing[#camera_missing+1]=item[2] end
    end
    local vector_ok=pcall(function() return engine.Vector3(0,0,0),engine.Vector2(1,1),engine.Color(255,255,205,55) end)
    if not vector_ok then missing[#missing+1]='vector_or_color_constructor' end
    emit('screen_gui_api missing='..table.concat(missing,','))
    emit('camera_api missing='..table.concat(camera_missing,','))
    local api={available=#missing==0,camera_available=#camera_missing==0,
        missing=table.concat(missing,','),count=0,kind='screen_gui'}
    local selector=CameraSelector.new(engine,emit)
    local world,gui,width,height,last_size,ticks=nil,nil,nil,nil,nil,0
    local function live(worlds,wanted)
        if type(worlds)~='table' or wanted==nil then return false end
        for _,value in pairs(worlds) do if value==wanted then return true end end
        return false
    end
    local function release(worlds)
        local w,g=world,gui
        world,gui,api.count=nil,nil,0
        api.camera_model,api.viewport=nil,nil
        if g~=nil and live(worlds,w) then pcall(Gui.reset,g);pcall(World.destroy_gui,w,g) end
    end
    local function target_world(worlds,main)
        -- Same UI-World strategy used by the existing native screen HUD addons.
        for _,value in ipairs(worlds) do if value~=main then return value end end
        for _,value in pairs(worlds) do if value~=main then return value end end
        return main
    end
    local function line(a,b,color,pixels)
        a,b=Projection.rect_clip(a,b,width,height)
        if not a then return false end
        local q=Projection.screen_quad(a,b,pixels)
        if not q then return false end
        -- Screen Gui.triangle uses x/z for the plane. Y is depth, not pixel y.
        local vertices={}
        for i=1,4 do vertices[i]=engine.Vector3(q[i][1],0,q[i][2]) end
        Gui.triangle(gui,vertices[1],vertices[2],vertices[3],1500,color)
        Gui.triangle(gui,vertices[1],vertices[3],vertices[4],1500,color)
        return true
    end
    function api:draw(segments)
        self.camera_model,self.viewport=nil,nil
        if not self.available then return false,self.missing end
        local worlds,main=App.worlds(),App.main_world()
        if not live(worlds,main) then release(worlds);selector:reset();return false,'main_world_unavailable' end
        local desired=target_world(worlds,main)
        if world~=desired then release(worlds);selector:reset() end
        if gui==nil then
            gui=assert(World.create_screen_gui(desired,'immediate','scale',1,1),'screen GUI creation failed')
            world=desired;emit('screen_gui_created ui_world='..tostring(desired~=main))
        end
        width,height=Gui.resolution()
        assert(type(width)=='number' and type(height)=='number' and width>0 and height>0 and width<=32768 and height<=32768,'screen resolution bound')
        local size=tostring(width)..'x'..tostring(height)
        if size~=last_size then emit('full_viewport size='..size..' clip=0,0,'..width..','..height);last_size=size end
        Gui.reset(gui);self.count=0;ticks=ticks+1
        if config.reference then
            -- Fixed L/R probes isolate GUI scissor/viewport behavior from 3D projection.
            local cyan=engine.Color(255,80,220,255)
            for _,x in ipairs({width*0.05,width*0.95}) do
                Gui.rect(gui,engine.Vector3(x-6,height/2-2,1500),engine.Vector2(12,4),cyan)
                Gui.rect(gui,engine.Vector3(x-2,height/2-6,1500),engine.Vector2(4,12),cyan)
            end
        end
        if not self.camera_available then return true,'camera_api_unavailable' end
        local model=selector:sample(main)
        if not model then return true,'camera_unavailable' end
        self.camera_model=model;self.viewport={width=width,height=height}
        local viewport=engine.Vector2(width,height)
        local argb=visual.color_argb or {255,255,255,255}
        local lock_color=engine.Color(argb[1],argb[2],argb[3],argb[4])
        local function project(p)
            local value=Camera.world_to_screen(model.camera,engine.Vector3(p[1],p[2],p[3]),nil,viewport)
            local point={V3.x(value),V3.y(value)}
            for i=1,2 do assert(point[i]==point[i] and math.abs(point[i])<1e12,'projected point bound') end
            return point
        end
        local function marker(spec,p)
            if not MarkerShapes.is_screen(spec) then return false end
            -- Use the real anchor, never a clipped endpoint, so a marker cannot
            -- falsely stick to a screen edge or the camera's near plane.
            local depth=(p[1]-model.position[1])*model.forward[1]
                +(p[2]-model.position[2])*model.forward[2]+(p[3]-model.position[3])*model.forward[3]
            if depth<model.near then return false end
            local visible=false
            local center=project(p)
            local shape=spec
            if spec.world_cross_half_m then
                -- Preserve the original world cross at close range; keep its
                -- enclosing circle outside the projected tips as it grows.
                local radius=spec.radius_px
                for _,stroke in ipairs(MarkerShapes.world({style='world_cross',half_size_m=spec.world_cross_half_m},p)) do
                    for _,tip in ipairs({stroke.from,stroke.to}) do
                        local z=(tip[1]-model.position[1])*model.forward[1]
                            +(tip[2]-model.position[2])*model.forward[2]+(tip[3]-model.position[3])*model.forward[3]
                        if z>=model.near then
                            local q=project(tip)
                            radius=math.max(radius,math.sqrt((q[1]-center[1])^2+(q[2]-center[2])^2)+3)
                        end
                    end
                end
                shape={style='ring',radius_px=radius,segments=spec.segments}
            end
            for _,stroke in ipairs(MarkerShapes.screen(shape,center)) do
                if line(stroke.from,stroke.to,lock_color,spec.width_px or 1.5) then visible=true end
            end
            return visible
        end
        for _,segment in ipairs(segments) do
            local a,b=Projection.near_clip(segment.from,segment.to,model.position,model.forward,model.near)
            if a then
                local pa,pb=project(a),project(b)
                local color=segment.reference and engine.Color(255,80,220,255)
                    or lock_color
                local pixels=segment.marker and ((visual.target_marker or {}).width_px or 1.5)
                    or (visual.line_width_px or 2)
                if line(pa,pb,color,pixels) then self.count=self.count+1 end
            end
            if marker(segment.start_marker,segment.from) then self.count=self.count+1 end
            if marker(segment.end_marker,segment.to) then self.count=self.count+1 end
            if marker(segment.estimated_marker,segment.to) then self.count=self.count+1 end
        end
        if ticks%120==0 then emit('screen_draw segments='..#segments..' visible='..self.count..' size='..size) end
        return true
    end
    function api:clear()
        self.camera_model,self.viewport=nil,nil
        local ok,worlds=pcall(App.worlds)
        if ok then release(worlds) else world,gui,self.count=nil,nil,0 end
        selector:reset()
    end
    return api
end
return M
