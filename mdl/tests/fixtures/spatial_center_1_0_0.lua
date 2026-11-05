-- Positional binding, not an exact network-ID mapping. Cache by runtime
-- handle: Unit.id may be absent or shared. Include non-animated mesh units.
local Data=require('probe_data')
local M={}
local function call(fn,...)
    if type(fn)~='function' then return nil end
    local ok,a,b=pcall(fn,...);if ok then return a,b end
end
local function distance(a,b)
    local n=0;for i=1,3 do n=n+(a[i]-b[i])^2 end;return math.sqrt(n)
end
function M.new(E,emit)
    local A,W,U,B=E.Application or{},E.World or{},E.Unit or{},E.Matrix4x4 or{}
    local world,scan,scan_cursor,next_scan,clock=nil,nil,1,0,0
    local candidates,index,refresh,bindings={}, {},1,{}
    local counts,scan_started,scan_age,diagnostics={},0,8,{}
    local animated,animated_refresh={},1
    local enemy_units={}
    local R={}
    function R.reset()
        world,scan,scan_cursor,next_scan=nil,nil,1,0;candidates,index,refresh,bindings={}, {},1,{}
        counts,scan_age,diagnostics={},8,{}
        animated,animated_refresh={},1;enemy_units={}
    end
    local function valid(unit)
        return call(U.alive,unit)==true and index[unit]~=nil
            and (type(U.world)~='function' or call(U.world,unit)==world)
    end
    local function sample(c)
        if not valid(c.unit) then c.pos=nil;c.pos1=nil;return end
        c.pos=Data.position(call(U.world_position,c.unit,0));c.pos1=nil;c.at=clock
        local nodes=call(U.num_scene_graph_items,c.unit)
        if type(nodes)=='number' and nodes>=2 then c.pos1=Data.position(call(U.world_position,c.unit,1)) end
    end
    local function separation(c,root)
        return math.min(c.pos and distance(c.pos,root)or math.huge,
            c.pos1 and distance(c.pos1,root)or math.huge)
    end
    function R.step(now)
        clock=now
        local current=call(A.main_world);local worlds=call(A.worlds);local live=false
        for _,w in pairs(type(worlds)=='table'and worlds or{})do if w==current then live=true end end
        if not live then R.reset();return end
        if world~=current then R.reset();world=current end
        if type(U.num_meshes)~='function'
            or type(U.world_position)~='function' then return end
        if not scan and now>=next_scan then
            local list=call(W.units,world)
            if type(list)=='table' and #list<=65536 then
                scan=list;scan_cursor=1;scan_started=now
                counts={alive=0,meshes=0,animated=0,no_id=0,duplicate_id=0,ids={}}
            end
            next_scan=now+2
        end
        if scan then
            local last=math.min(#scan,scan_cursor+63)
            for i=scan_cursor,last do
                local u=scan[i]
                if call(U.alive,u)==true then
                    counts.alive=counts.alive+1
                    local meshes=call(U.num_meshes,u)
                    if type(meshes)=='number' and meshes>0 then
                        counts.meshes=counts.meshes+1
                        local is_animated=call(U.has_animation_state_machine,u)==true
                        if is_animated then counts.animated=counts.animated+1 end
                        local uid=call(U.id,u)
                        if uid==nil then counts.no_id=counts.no_id+1
                        elseif counts.ids[uid]then counts.duplicate_id=counts.duplicate_id+1
                        else counts.ids[uid]=true end
                        -- Unit.id is diagnostic only; key the cache by the actual handle.
                        local c=index[u]
                        if not c and #candidates<32768 then
                            c={unit=u};index[u]=c;candidates[#candidates+1]=c
                        end
                        if c then
                            c.animated=is_animated
                            if is_animated and not c.in_animated then
                                c.in_animated=true;animated[#animated+1]=c
                            end
                            sample(c)
                        end
                    end
                end
            end
            scan_cursor=last+1
            if scan_cursor>#scan then
                scan_age=math.max(2,now-scan_started+2)
                if emit then emit('CENTER_SCAN',string.format(
                    'units=%d alive=%d mesh_units=%d animated_meshes=%d no_id=%d duplicate_ids=%d cached=%d',
                    #scan,counts.alive,counts.meshes,counts.animated,counts.no_id,counts.duplicate_id,#candidates)) end
                counts={}
                scan=nil
            end
        end
        -- Share the existing 32 refresh slots: moving animated models should
        -- not wait behind ten thousand mostly static scenery meshes.
        local fast=math.min(16,#animated)
        for _=1,fast do
            if animated_refresh>#animated then animated_refresh=1 end
            sample(animated[animated_refresh]);animated_refresh=animated_refresh+1
        end
        for _=1,math.min(32-fast,#candidates)do
            if refresh>#candidates then refresh=1 end
            sample(candidates[refresh]);refresh=refresh+1
        end
        -- Dead handles are not allowed to exhaust the bounded cache.
        if not scan then
            local keep={}
            for _,c in ipairs(candidates)do
                if c.pos or c.pos1 then keep[#keep+1]=c else index[c.unit]=nil end
            end
            candidates=keep
            local moving={}
            for _,c in ipairs(animated)do
                if index[c.unit]==c and c.animated and (c.pos or c.pos1)then
                    moving[#moving+1]=c
                else c.in_animated=nil end
            end
            animated=moving
        end
    end
    function R.resolve(id,root)
        if not root or not world then return nil,'SPATIAL_WARMING' end
        local best,runner,first,second=nil,nil,math.huge,math.huge
        local nearby={};local nearest=math.huge
        for _,c in ipairs(candidates)do
            if c.at and clock-c.at<=scan_age then
                local d=separation(c,root);nearest=math.min(nearest,d)
                if d<=12 then nearby[#nearby+1]={c=c,d=d} end
            end
        end
        local function report(why,d)
            if emit and clock>=(diagnostics[id]or 0)then
                diagnostics[id]=clock+2
                emit('CENTER_MATCH',string.format('target=%s result=%s cached=%d nearby=%d nearest=%.3f second=%.3f best_animated=%s second_animated=%s capped=%s',
                    tostring(id),why,#candidates,#nearby,d,second,tostring(best and best.animated),tostring(runner and runner.animated),tostring(#nearby>=48)))
            end
        end
        if #nearby>48 then
            table.sort(nearby,function(a,b)return a.d<b.d end)
            for i=#nearby,49,-1 do nearby[i]=nil end
        end
        local prior=bindings[id] and bindings[id].c
        local prior_distance=math.huge
        if prior and valid(prior.unit)then
            sample(prior);prior_distance=separation(prior,root)
        end
        for _,row in ipairs(nearby)do
            local c=row.c
            if valid(c.unit)then
                sample(c)
                if c.pos or c.pos1 then
                    local d=separation(c,root)
                    if d<first then second,runner,first,best=first,best,d,c elseif d<second then second,runner=d,c end
                end
            end
        end
        -- This marker is a visual aid. The user accepts overlapping models;
        -- keep a close existing match to avoid flicker, otherwise use nearest.
        if prior and prior_distance<=.4 and prior_distance<=first+.10 then
            best=prior;first=prior_distance
        end
        if not best or first>.4 then bindings[id]=nil;report('SPATIAL_NO_MATCH',math.min(first,nearest));return nil,'SPATIAL_NO_MATCH' end
        if not valid(best.unit) then bindings[id]=nil;return nil,'SPATIAL_UNIT_GONE' end
        sample(best)
        if separation(best,root)>.4 then bindings[id]=nil;return nil,'SPATIAL_POSE_MISMATCH' end
        local binding=bindings[id]
        if not binding or binding.c~=best or clock-binding.last>.25 then
            binding={c=best,seen=0,last=-1};bindings[id]=binding
        end
        if clock>binding.last then binding.seen=binding.seen+1;binding.last=clock end
        if binding.seen<3 then return nil,'SPATIAL_CONFIRMING' end
        local pose,half=call(U.box,best.unit,true)
        local center=pose and Data.position(call(B.translation,pose));local extent=Data.position(half)
        if not center or not extent then return nil,'SPATIAL_BOX_UNAVAILABLE' end
        local n=0;for i=1,3 do if extent[i]<0 or extent[i]>100 then return nil,'SPATIAL_BOX_INVALID' end;n=n+extent[i]^2 end
        if n<.0001 or distance(center,root)>2*math.sqrt(n)+3 then return nil,'SPATIAL_BOX_INVALID' end
        sample(best)
        if not valid(best.unit) or separation(best,root)>.4 then return nil,'SPATIAL_POSE_MISMATCH' end
        report('UNIT_SPATIAL_BOX_CENTER',first)
        return center,'UNIT_SPATIAL_BOX_CENTER'
    end
    function R.forget_enemy(key)enemy_units[key]=nil end
    function R.enemy_position(key,root,network_id)
        local c=enemy_units[key]
        if c and not valid(c.unit)then enemy_units[key]=nil;c=nil end
        -- Reuse a center already confirmed against this authoritative target.
        if not c and network_id and bindings[network_id]then
            local prior=bindings[network_id].c
            if prior and valid(prior.unit)then c=prior end
        end
        if not c and root then
            local best=1.0
            for _,candidate in ipairs(candidates)do
                if candidate.at and clock-candidate.at<=scan_age and separation(candidate,root)<=2 then
                    sample(candidate)
                    local d=separation(candidate,root)
                    if d<best then best,c=d,candidate end
                end
            end
        end
        if not c or not valid(c.unit)then return nil end
        sample(c)
        local pose,half=call(U.box,c.unit,true)
        local point=pose and Data.position(call(B.translation,pose));local ext=Data.position(half)
        if not point or not ext then return nil end
        local size=0
        for i=1,3 do if ext[i]<0 or ext[i]>100 then return nil end;size=size+ext[i]^2 end
        if size<.0001 or separation(c,point)>2*math.sqrt(size)+3 or not valid(c.unit)then return nil end
        enemy_units[key]=c
        return point
    end
    return R
end
return M
