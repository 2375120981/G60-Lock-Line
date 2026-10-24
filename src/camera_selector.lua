-- Read-only public engine queries. Select a Unit-owned camera only if its pose
-- matches the camera that most recently rendered this World. No guessed FOV.
local M={}
function M.new(engine,emit)
    local World,Unit,Camera,Matrix,V3=engine.World,engine.Unit,engine.Camera,engine.Matrix4x4,engine.Vector3
    local api={}
    local current_world,candidates,scan,cursor,cooldown=nil,{},nil,1,0
    local last_status
    local function components(v)
        local p={V3.x(v),V3.y(v),V3.z(v)}
        for i=1,3 do assert(type(p[i])=='number' and p[i]==p[i] and math.abs(p[i])<10000000,'camera vector bound') end
        return p
    end
    local function pose_values(pose)
        return components(Matrix.translation(pose)),components(Matrix.y(pose)),components(Matrix.x(pose)),components(Matrix.z(pose))
    end
    local function status(value)
        if value~=last_status then emit('camera='..value);last_status=value end
    end
    function api:reset()
        current_world,candidates,scan,cursor,cooldown=nil,{},nil,1,0
        last_status=nil
    end
    function api:sample(world)
        if world~=current_world then self:reset();current_world=world end
        cooldown=math.max(0,cooldown-1)
        if scan==nil and #candidates==0 and cooldown==0 then
            scan=World.units(world);cursor=1
            assert(type(scan)=='table' and #scan<=65536,'camera unit scan bound')
            emit('camera_scan units='..#scan)
        end
        if scan then
            local last=math.min(#scan,cursor+63)
            for i=cursor,last do
                local unit=scan[i]
                local ok,count=pcall(function()
                    if Unit.alive(unit)~=true then return 0 end
                    return Unit.num_cameras(unit)
                end)
                if ok and type(count)=='number' and count>=1 and count<=8 then
                    for index=1,count do
                        assert(#candidates<64,'camera candidate bound')
                        candidates[#candidates+1]={unit=unit,index=index}
                    end
                end
            end
            cursor=last+1
            if cursor>#scan then scan=nil;cooldown=60;emit('camera_scan_complete candidates='..#candidates) end
        end
        local position,forward,right,up=pose_values(World.debug_camera_pose(world))
        local best,best_score,ambiguous,live_candidates=nil,nil,false,{}
        for _,candidate in ipairs(candidates) do
            local ok,result=pcall(function()
                if Unit.alive(candidate.unit)~=true or Unit.num_cameras(candidate.unit)<candidate.index then return nil end
                -- Resolve the camera afresh: never cache a camera userdata from a previous frame.
                local camera=Unit.camera(candidate.unit,candidate.index)
                local p,f,r,u=pose_values(Camera.world_pose(camera))
                local distance,axes=0,0
                for i=1,3 do
                    distance=distance+(p[i]-position[i])^2
                    axes=axes+(f[i]-forward[i])^2+(r[i]-right[i])^2+(u[i]-up[i])^2
                end
                return {camera=camera,position=p,forward=f,right=r,up=u,score=distance+axes,eligible=distance<=0.25 and axes<=0.05}
            end)
            if ok and result then
                live_candidates[#live_candidates+1]=candidate
                if result.eligible then
                    if best_score==nil or result.score<best_score-0.000001 then best=result;best_score=result.score;ambiguous=false
                    elseif math.abs(result.score-best_score)<=0.000001 then ambiguous=true end
                end
            end
        end
        candidates=live_candidates
        if not best or ambiguous then status(ambiguous and 'ambiguous' or (#candidates==0 and 'not_found' or 'pose_mismatch'));return nil end
        local near=Camera.near_range(best.camera)
        assert(type(near)=='number' and near==near and near>0 and near<100,'camera near range bound')
        best.near=near+0.001
        status('matched_last_render_pose')
        return best
    end
    return api
end
return M
