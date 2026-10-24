-- Our independent scene mesh uses immutable HDR materials and native depth/Bloom.
local M={}
local function has(o,n) return type(o)=='table' and type(o[n])=='function' end
local function sphere()
    local vertices,indices={},{}
    local rings,sides=8,16
    for j=0,rings do
        local theta=j*math.pi/rings
        local st,ct=math.sin(theta),math.cos(theta)
        for i=0,sides do
            local phi=i*2*math.pi/sides
            local sp,cp=math.sin(phi),math.cos(phi)
            local x,y,z=st*cp,st*sp,ct
            -- Position/normal/tangent/binormal/UV/color: 18 floats.
            for _,v in ipairs({x,y,z,x,y,z,-sp,cp,0,-ct*cp,-ct*sp,st,i/sides,j/rings,1,1,1,1}) do
                vertices[#vertices+1]=v
            end
        end
    end
    for j=0,rings-1 do
        for i=0,sides-1 do
            local a=j*(sides+1)+i
            local b=a+sides+1
            if j<rings-1 then
                indices[#indices+1]=a;indices[#indices+1]=b;indices[#indices+1]=b+1
            end
            if j>0 then
                indices[#indices+1]=a;indices[#indices+1]=b+1;indices[#indices+1]=a+1
            end
        end
    end
    return vertices,indices
end
function M.new(engine,emit,spec)
    spec=spec or {enabled=false}
    local api={enabled=spec.enabled==true,count=0}
    if not api.enabled then
        function api:sync() return true end
        function api:clear() end
        return api
    end
    local App,World,Unit,PM,RB=engine.Application,engine.World,engine.Unit,engine.ProceduralMesh,engine.RenderBuffer
    local missing={}
    for _,item in ipairs({{App,'worlds'},{App,'main_world'},{World,'spawn_unit'},
        {World,'destroy_unit'},{World,'update_unit'},{Unit,'alive'},{Unit,'node'},
        {Unit,'set_local_position'},{Unit,'set_local_scale'},
        {PM,'create'},{PM,'set_materials'},{PM,'set_batch_info'},{PM,'set_bounding_box'},{PM,'add_resource'},
        {RB,'format'},{RB,'create_description'},{RB,'create_buffer'},{RB,'destroy_buffer'},{RB,'destroy_description'}}) do
        if not has(item[1],item[2]) then missing[#missing+1]=item[2] end
    end
    local destroy_mesh=has(PM,'destroy_mesh') and PM.destroy_mesh or (has(PM,'destroy') and PM.destroy)
    if not destroy_mesh then missing[#missing+1]='destroy_mesh' end
    for _,name in ipairs({'MO_VIEWPORT_VISIBLE_FLAG','MO_TRIANGLE_LIST'}) do
        if type(PM)~='table' or type(PM[name])~='number' then missing[#missing+1]=name end
    end
    for _,name in ipairs({'RB_FLOAT_COMPONENT','RB_VALIDITY_STATIC','RB_VERTEX_BUFFER_VIEW',
        'RB_INDEX_BUFFER_VIEW','RB_VERTEX_DESCRIPTION','RB_POSITION_SEMANTIC','RB_NORMAL_SEMANTIC',
        'RB_TANGENT_SEMANTIC','RB_BINORMAL_SEMANTIC','RB_TEXCOORD_SEMANTIC','RB_COLOR_SEMANTIC'}) do
        if type(RB)~='table' or type(RB[name])~='number' then missing[#missing+1]=name end
    end
    api.available=#missing==0
    emit('bloom_api available='..tostring(api.available)..' missing='..table.concat(missing,','))
    local world,units,failed_world=nil,{},nil
    local vertex_data,index_data=sphere()
    local function live(worlds,wanted)
        if wanted==nil then return false end
        for _,w in pairs(worlds or {}) do if w==wanted then return true end end
        return false
    end
    local function dispose(entry,worlds)
        if live(worlds,world) and entry.unit then
            local ok,alive=pcall(Unit.alive,entry.unit)
            if ok and alive then
                if entry.mesh then pcall(destroy_mesh,entry.mesh) end
                pcall(World.destroy_unit,world,entry.unit)
            end
        end
        -- Drop our buffer references even when the old World has already ended.
        for _,name in ipairs({'indices','vertices'}) do
            if entry[name] then pcall(RB.destroy_buffer,entry[name]);entry[name]=nil end
        end
        if entry.description then pcall(RB.destroy_description,entry.description);entry.description=nil end
        entry.unit,entry.mesh=nil,nil
    end
    local function clear(worlds)
        for _,entry in pairs(units) do dispose(entry,worlds) end
        units,api.count={},0
    end
    function api:clear()
        if not self.available then return end
        local ok,worlds=pcall(App.worlds)
        clear(ok and worlds or {})
    end
    local function radius(p,camera,viewport)
        if not camera or not viewport or not camera.right then return spec.marker_radius_m end
        local depth=0
        for i=1,3 do depth=depth+(p[i]-camera.position[i])*camera.forward[i] end
        if depth<camera.near then return spec.marker_radius_m end
        local V3=engine.Vector3
        local size=engine.Vector2(viewport.width,viewport.height)
        local a=engine.Camera.world_to_screen(camera.camera,V3(p[1],p[2],p[3]),nil,size)
        local b=engine.Camera.world_to_screen(camera.camera,
            V3(p[1]+camera.right[1],p[2]+camera.right[2],p[3]+camera.right[3]),nil,size)
        local dx,dy=V3.x(b)-V3.x(a),V3.y(b)-V3.y(a)
        local pixels=math.sqrt(dx*dx+dy*dy)
        if pixels~=pixels or pixels<0.001 or pixels>1e8 then return spec.marker_radius_m end
        return math.max(0.02,math.min(2,spec.point_radius_px/pixels))
    end
    local function create(entry,p)
        entry.unit=assert(World.spawn_unit(world,spec.marker_resource,p),'Bloom marker spawn failed')
        entry.node=Unit.node(entry.unit,'root')
        local channels={}
        for _,channel in ipairs({{'RB_POSITION_SEMANTIC',3},{'RB_NORMAL_SEMANTIC',3},
            {'RB_TANGENT_SEMANTIC',3},{'RB_BINORMAL_SEMANTIC',3},{'RB_TEXCOORD_SEMANTIC',2},{'RB_COLOR_SEMANTIC',4}}) do
            local n=channel[2]
            channels[#channels+1]={format=RB.format(RB.RB_FLOAT_COMPONENT,true,false,32,32,n>=3 and 32 or 0,n==4 and 32 or 0),
                semantic=RB[channel[1]],vb_index=0,set=0,instance=false}
        end
        entry.description=assert(RB.create_description(RB.RB_VERTEX_DESCRIPTION,channels),'vertex description failed')
        entry.vertices=assert(RB.create_buffer(RB.RB_VALIDITY_STATIC,RB.RB_VERTEX_BUFFER_VIEW,18*4,vertex_data),'vertex buffer failed')
        entry.indices=assert(RB.create_buffer(RB.RB_VALIDITY_STATIC,RB.RB_INDEX_BUFFER_VIEW,4,index_data),'index buffer failed')
        entry.mesh=assert(PM.create(entry.unit,'root','g60-bloom',PM.MO_VIEWPORT_VISIBLE_FLAG),'procedural mesh failed')
        PM.set_bounding_box(entry.mesh,engine.Vector3(-1,-1,-1),engine.Vector3(1,1,1))
        PM.set_batch_info(entry.mesh,{{primitive_type=PM.MO_TRIANGLE_LIST,material_index=0,
            vertex_offset=0,index_offset=0,primitives=#index_data/3,vertices=0,instances=1}})
        PM.add_resource(entry.mesh,entry.description)
        PM.add_resource(entry.mesh,entry.vertices)
        PM.add_resource(entry.mesh,entry.indices)
    end
    function api:sync(rows,camera,viewport)
        if not self.available then return false,'bloom_api_unavailable' end
        local worlds,main=App.worlds(),App.main_world()
        if not live(worlds,main) then clear(worlds);world=nil;return false,'main_world_unavailable' end
        if world~=main then clear(worlds);world=main;failed_world=nil end
        if failed_world==main then return false,'bloom_backend_disabled' end
        local seen={}
        for _,row in ipairs(rows) do seen[row.key]=true end
        for key,entry in pairs(units) do
            if not seen[key] then dispose(entry,worlds);units[key]=nil end
        end
        for _,row in ipairs(rows) do
            local ok,why=pcall(function()
                local entry=units[row.key]
                if entry and not Unit.alive(entry.unit) then dispose(entry,worlds);units[row.key]=nil;entry=nil end
                if not entry then
                    entry={};units[row.key]=entry
                    create(entry,engine.Vector3(row.from[1],row.from[2],row.from[3]))
                    emit('bloom_marker_created id='..tostring(row.id)..' resource='..spec.marker_resource)
                end
                Unit.set_local_position(entry.unit,entry.node,engine.Vector3(row.from[1],row.from[2],row.from[3]))
                local r=radius(row.from,camera,viewport)
                Unit.set_local_scale(entry.unit,entry.node,engine.Vector3(r,r,r))
                World.update_unit(main,entry.unit)
                if entry.locked~=row.locked then
                    local material=row.locked and spec.locked_material or spec.unlocked_material
                    PM.set_materials(entry.mesh,{material})
                    entry.locked=row.locked
                    emit('bloom_state id='..tostring(row.id)..' locked='..tostring(row.locked)..' material='..material)
                end
            end)
            if not ok then
                emit('bloom_error '..tostring(why));clear(worlds);failed_world=main
                return false,tostring(why)
            end
        end
        self.count=0;for _ in pairs(units) do self.count=self.count+1 end
        return true
    end
    return api
end
return M
