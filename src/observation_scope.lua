-- Scope is a read-only view of the last rendered main-World camera position.
local M={}
local function valid(p)
    if type(p)~='table' then return false end
    for i=1,3 do
        if type(p[i])~='number' or p[i]~=p[i] or math.abs(p[i])>=10000000 then return false end
    end
    return true
end
M.valid_position=valid
function M.camera_origin(engine)
    local App,World,Matrix,V3=engine.Application,engine.World,engine.Matrix4x4,engine.Vector3
    local main,worlds=App.main_world(),App.worlds()
    local live=false
    if main~=nil then for _,world in pairs(worlds or {}) do if world==main then live=true;break end end end
    if not live then return nil,'main_world_unavailable' end
    local p=Matrix.translation(World.debug_camera_pose(main))
    local origin={V3.x(p),V3.y(p),V3.z(p)}
    if not valid(origin) then return nil,'camera_position_invalid' end
    return origin
end
function M.contains(origin,p,radius)
    if not valid(origin) or not valid(p) or type(radius)~='number' or not (radius>0 and radius<=1000) then
        return false
    end
    local squared=0
    for i=1,3 do squared=squared+(p[i]-origin[i])^2 end
    return squared<=radius*radius,math.sqrt(squared)
end
function M.active(row)
    if row.remote_active and row.locally_owned==false then
        return row.explosive_ready==true and not row.terminal
            and (row.remote_phase==2 or row.remote_phase==3 or row.remote_phase==4)
    end
    return row.explosive_ready==true and not row.terminal and row.eligible==true and row.behavior==4
        and (row.state==2 or row.state==3 or row.state==4)
end
return M
