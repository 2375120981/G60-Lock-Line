-- Public engine network-ID <-> Unit mapping, checked both ways each sample.
-- Unit.box returns the pose of the oriented mesh bounding-box center.
local Data=require('probe_data')
local Spatial=require('probe_spatial_center')
local M={}
local function call(fn,...)
    if type(fn)~='function' then return nil end
    local ok,a,b=pcall(fn,...);if ok then return a,b end
end
function M.new(E,emit)
    local A,N,G,U,X,B=E.Application or{},E.Network or{},E.GameSession or{},
        E.Unit or{},E.UnitSynchronizer or{},E.Matrix4x4 or{}
    local R={}
    local spatial=Spatial.new(E,emit)
    function R.reset() spatial.reset() end
    function R.step(now,active) spatial.step(now,active) end
    function R.enemy_position(key,root,id)return spatial.enemy_position(key,root,id)end
    function R.forget_enemy(key)spatial.forget_enemy(key)end
    local function direct(session,id,root)
        if type(G.unit_synchronizer)~='function' or type(X.game_object_id_to_unit)~='function'
            or type(X.unit_to_game_object_id)~='function' then return nil,'SYNC_API_ABSENT' end
        if call(N.game_session)~=session or call(G.game_object_exists,session,id)~=true then return nil,'OBJECT_GONE' end
        local sync=call(G.unit_synchronizer,session)
        if sync==nil then return nil,'NO_SYNCHRONIZER' end
        local unit=call(X.game_object_id_to_unit,sync,id)
        if unit==nil then return nil,'UNIT_NOT_MAPPED' end
        if call(U.alive,unit)~=true then return nil,'UNIT_NOT_ALIVE' end
        if call(X.unit_to_game_object_id,sync,unit)~=id then return nil,'UNIT_ID_MISMATCH' end
        local world=call(A.main_world);local worlds=call(A.worlds);local live=false
        for _,w in pairs(type(worlds)=='table' and worlds or{})do if w==world then live=true end end
        if not live then return nil,'NO_WORLD' end
        if type(U.world)=='function' and call(U.world,unit)~=world then return nil,'UNIT_WORLD_MISMATCH' end
        if type(U.box)~='function' or type(B.translation)~='function' then return nil,'BOX_API_ABSENT' end
        local pose,half=call(U.box,unit,true)
        local center=pose and Data.position(call(B.translation,pose))
        local extent=Data.position(half)
        if not center or not extent then return nil,'BOX_UNAVAILABLE' end
        local size=0
        for i=1,3 do
            if extent[i]<0 or extent[i]>100 then return nil,'BOX_INVALID' end
            size=size+extent[i]^2
        end
        if size<.0001 then return nil,'BOX_EMPTY' end
        if root then
            local dist=0;for i=1,3 do dist=dist+(center[i]-root[i])^2 end
            if dist>(2*math.sqrt(size)+3)^2 then return nil,'BOX_TOO_FAR_FROM_ROOT' end
        end
        -- Do not retain any Unit/vector/matrix userdata between frames.
        if call(N.game_session)~=session or call(G.game_object_exists,session,id)~=true
            or call(U.alive,unit)~=true or call(X.unit_to_game_object_id,sync,unit)~=id then return nil,'OBJECT_CHANGED' end
        return center,'UNIT_BOX_CENTER'
    end
    function R.resolve(session,id,root)
        local p,why=direct(session,id,root)
        if p then return p,why end
        if why=='NO_SYNCHRONIZER' or why=='UNIT_NOT_MAPPED' or why=='SYNC_API_ABSENT' then
            local point,status=spatial.resolve(id,root)
            return point,point and status or (why..'/'..status)
        end
        return nil,why
    end
    return R
end
return M
