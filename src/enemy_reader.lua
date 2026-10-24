-- Scene actors for local prediction. No AI, gameplay or network functions called.
local L=require('g60line.layout')
local Data=require('g60line.target_data')
local Scope=require('g60line.observation_scope')
local M={}
local function alive(d,e)
    -- Decode the same death checks used by the pinned native target validator.
    local tags=d.ptr(d.base+0x3326430)
    local ti=d.hash(tags+0x18,e.id,4096)
    if ti then
        local flags=d.read(d.ptr(tags+0x38)+ti*8,8)
        if math.floor(L.u32(flags,0)/2^25)%2~=0 then return false end
    end
    local actors=d.ptr(d.base+0x3326688)
    local ai=d.hash(actors+0x1030,e.id,4096)
    if ai then
        local address=d.ptr(d.ptr(actors+0x1048)+ai*8)
        assert(address==e.address and d.read(address,24)==e.identity,'enemy AI identity changed')
        return d.u32(d.ptr(actors+0x1058)+ai*0x1b8+0x19c)<2
    end
    local states=d.ptr(d.base+0x346d528)
    local si=d.hash(states+0xc5f48,e.handle,4096)
    return si~=nil and d.read(states+0xc5f7f+si*12,1):byte()==0
end
function M.one(reader,base,exe,id,key,config)
    local d=Data.new(reader,base,exe)
    local e=d.entity(id)
    if not e or key and e.identity:sub(1,20)~=key then return nil end
    local profile=config.estimation_enemies[e.resource]
    if not profile or not alive(d,e) then return nil end
    local point,kind=d.unit_position(e,config.pose_getters,true)
    assert(d.validate(),'enemy snapshot changed')
    return {id=id,key=e.identity:sub(1,20),resource=e.resource,point=point,
        endpoint_kind=kind,priority=profile.priority,alive=true}
end
function M.capture(reader,base,exe,ids,sources,config,cursor,preferred)
    local result={}
    local stats={checked=0,errors=0}
    local limit=math.min(#ids,config.estimation.enemy_read_limit or 96)
    if #ids==0 or #sources==0 then return result,1,stats end
    cursor=cursor or 1
    local order,seen,available={},{},{}
    for _,id in ipairs(ids) do available[id]=true end
    for _,id in ipairs(preferred or {}) do
        if available[id] and not seen[id] and #order<limit then order[#order+1]=id;seen[id]=true end
    end
    local next_cursor=cursor
    for k=0,#ids-1 do
        if #order>=limit then break end
        local index=(cursor+k-1)%#ids+1
        local id=ids[index]
        if not seen[id] then order[#order+1]=id;seen[id]=true end
        next_cursor=index%#ids+1
    end
    for _,id in ipairs(order) do
        local ok,row=pcall(M.one,reader,base,exe,id,nil,config)
        stats.checked=stats.checked+1
        if not ok then stats.errors=stats.errors+1;stats.last_error=tostring(row) end
        if ok and row then
            for _,p in ipairs(sources) do
                if Scope.contains(p,row.point,config.estimation.candidate_radius_m) then
                    result[#result+1]=row;break
                end
            end
        end
    end
    return result,next_cursor,stats
end
return M
