-- Diagnostic observations only. Never promote replicated stage values to a lock.
local L = require('g60line.layout')
local Data = require('g60line.target_data')
local Scope = require('g60line.observation_scope')
local M = {}
function M.remote_active(snapshot,owned,ready,terminal)
    -- Local AI update flags/active prefix are not the remote display gate.
    return owned==false and ready==true and not terminal and snapshot and not snapshot.error
        and snapshot.behavior==4 and (snapshot.state==2 or snapshot.state==3 or snapshot.state==4)
        and Scope.valid_position(snapshot.from) and snapshot.index<snapshot.total or false
end
function M.decode(mirror)
    assert(type(mirror)=='string' and #mirror==0xa0,'replica record size')
    local state,behavior=L.u32(mirror,0),L.u32(mirror,4)
    assert(state<=32 and behavior<=693,'replica state bound')
    local hex={}
    for i=1,#mirror do hex[i]=string.format('%02x',mirror:byte(i)) end
    return {state=state,behavior=behavior,source_id=L.u32(mirror,0x7c),
        flags=L.u32(mirror,0x78),event=L.u32(mirror,0x88),raw=table.concat(hex)}
end
function M.capture(reader,base,exe,index,identity,config)
    -- Use a separate snapshot so a diagnostic failure cannot suppress valid HUD data.
    local d=Data.new(reader,base,exe)
    local manager=d.ptr(base+0x3326740)
    local header=d.read(manager,0x70)
    local capacity,count=L.u32(header,0x20),L.u32(header,0x2c)
    local active,total=L.u32(header,0x34),L.u32(header,0x30)
    assert(active<=total and total<=count and count<=capacity and capacity<=4096
        and index>=0 and index%1==0 and index<count,'replica index bound')
    local address=d.ptr(L.pointer(header,0x58)+index*8)
    assert(d.read(address,24)==identity,'replica entity changed')
    local snapshot=M.decode(d.read(L.pointer(header,0x68)+index*0xa0,0xa0))
    snapshot.index,snapshot.active,snapshot.total=index,active,total
    snapshot.entity_flags=L.u32(identity,20)
    local source=d.entity(L.u32(identity,8))
    assert(source and source.identity==identity,'replica source changed')
    local pose_ok,pose=pcall(d.unit_position,source,config.pose_getters,false)
    if pose_ok then snapshot.from=pose else snapshot.position_error=tostring(pose) end
    assert(d.validate(),'replica observation changed')
    return snapshot
end
return M
