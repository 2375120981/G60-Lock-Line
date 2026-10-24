-- Adapted from etxp/HD2-G60-Smart-Targeting (MIT); see THIRD-PARTY-NOTICES.md.
-- Bounded observed entity/Unit/motion reads shared by experimental selection.
local ffi=require('ffi')
local L=require('g60line.layout')
local M={}
local function mul(a,b)
    local al,bl=a%65536,b%65536
    return (al*bl+((math.floor(a/65536)*bl+math.floor(b/65536)*al)%65536)*65536)%4294967296
end
function M.float(s,o)
    local v=ffi.new('uint32_t[1]',L.u32(s,o));local f=tonumber(ffi.cast('float *',v)[0])
    assert(f==f and math.abs(f)<1000000,'nonfinite target data');return f
end
function M.vector(s,o) return {M.float(s,o),M.float(s,o+4),M.float(s,o+8)} end
function M.new(reader,base,exe)
    local guards,total,calls={},0,0
    local d={base=base,exe=exe}
    function d.read(a,n)
        assert(type(a)=='number' and a%1==0 and a>=65536 and n>0 and n<=32768 and a+n<2^47,'target read bound')
        total=total+n;calls=calls+1;assert(total<=262144 and calls<=4096,'target data budget')
        local s=reader(a,n);assert(type(s)=='string' and #s==n,'short target read')
        guards[#guards+1]={a,n,s};return s
    end
    function d.ptr(a,align) return L.pointer(d.read(a,8),0,align) end
    function d.u32(a) return L.u32(d.read(a,4),0) end
    function d.hash(a,id,limit)
        local h=d.read(a,20)
        local entries,cap,empty,factor=L.pointer(h,0,4),L.u32(h,8),L.u32(h,12),L.u32(h,16)
        assert(cap>0 and cap<=1048576,'target hash capacity')
        local c=cap;while c>1 and c%2==0 do c=c/2 end;assert(c==1,'target hash not power of two')
        if id==empty then return nil end
        for probe=0,math.min(cap,256)-1 do
            local row=d.read(entries+((mul(id,factor)+probe)%cap)*8,8)
            local key,index=L.u32(row,0),L.u32(row,4)
            if key==empty then return nil end
            if key==id then
                if index==0xffffffff then return nil end
                assert(index<limit,'target index bound');return index
            end
        end
        error('target hash probe budget')
    end
    d.root=d.ptr(base+0x346bf98)
    d.invalid=d.u32(base+0x3483c20)
    local entities={}
    function d.entity(id)
        if entities[id] then return entities[id] end
        local index=d.hash(d.root+0xf1aeb0,id,2048)
        if not index then return nil end
        local address=d.root+0xf32f18+index*24
        local identity=d.read(address,24)
        assert(L.u32(identity,8)==id,'target entity identity mismatch')
        local e={id=id,address=address,identity=identity,resource=L.hex64(identity,0),handle=L.u32(identity,12),network=L.u32(identity,16)}
        entities[id]=e;return e
    end
    function d.unit(e)
        assert(e.handle~=0,'target Unit missing')
        local manager=d.ptr(exe+0x1a100f0)
        local index=e.handle%0x400000;local count=d.u32(manager+0x98)
        assert(count<=0x400000 and index<count,'target Unit index')
        assert(d.read(d.ptr(manager+0xa0)+index,1):byte()==math.floor(e.handle/0x400000)%256,'target Unit generation changed')
        local unit=d.ptr(d.ptr(manager+0x88)+index*8)
        assert(d.u32(unit+8)==e.handle,'Unit identity mismatch')
        return unit
    end
    function d.position(e)
        local manager=d.ptr(base+0x3326508)
        local i=assert(d.hash(manager+0x40,e.id,4096),'target motion missing')
        return M.vector(d.read(d.ptr(manager+0x68,4)+i*0x308+0x2e0,12),0)
    end
    -- Read-only adaptation of upstream explosive_context.lua. These records
    -- outlive a requested explosion, so selection/Unit existence alone is not
    -- sufficient to keep a target indicator alive.
    function d.explosive_lifecycle(e)
        local manager=d.ptr(base+0x3326728)
        local header=d.read(manager,0x70)
        local count,capacity=L.u32(header,0x24),L.u32(header,0x18)
        assert(count<=4096 and count<=capacity and capacity<=1048576,'explosive array bound')
        local function missing() return {ready=false,terminal=false,reason='explosive_component_missing'} end
        if count==0 then return missing() end
        local index=d.hash(manager+0x38,e.id,count)
        if not index then return missing() end
        local entity=d.ptr(L.pointer(header,0x50)+index*8)
        assert(entity==e.address and d.read(entity,24)==e.identity,'explosive entity identity changed')
        local state=d.read(L.pointer(header,0x60,4)+index*64,64)
        local network=d.read(L.pointer(header,0x68,4)+index*56,56)
        if L.u32(state,0x38)~=2 then
            return {ready=false,terminal=false,reason='unsupported_explosive_mode'}
        end
        local requested,processed,secondary=network:byte(2),state:byte(1),state:byte(0xd)
        local terminal=requested~=0 or processed~=0 or secondary~=0
        return {ready=true,terminal=terminal,reason=terminal and 'explosion_requested' or 'explosive_alive',
            flags=string.format('%d,%d,%d',requested,processed,secondary)}
    end
    -- Read the rendered Unit's world-pose translation, not the selection cache.
    -- Accessors are whitelisted leaf lea/load+ret methods from the fixed upstream
    -- profile. We decode them; we never call executable addresses.
    function d.unit_position(e,getters,prefer_body)
        local unit=d.unit(e)
        local getter=d.ptr(d.ptr(unit)+0xe8)
        local layout=assert(getters[getter-exe],'unsupported Unit scenegraph accessor')
        local expected=layout[3]:gsub('..',function(pair) return string.char(tonumber(pair,16)) end)
        assert(d.read(getter,#expected)==expected,'Unit scenegraph accessor changed')
        local graph=layout[2] and d.ptr(unit+layout[1]) or unit+layout[1]
        local nodes=d.u32(graph+0x10)
        assert(nodes>0 and nodes<=4096,'Unit scenegraph node count')
        local index,kind=0,'unit_root'
        if prefer_body and nodes<=512 then
            local names=d.read(d.ptr(graph+0x40,4),nodes*4)
            local found
            for i=0,nodes-1 do
                if L.u32(names,i*4)==0x9b115563 then
                    assert(found==nil,'ambiguous body anchor');found=i
                end
            end
            if found~=nil then index=found;kind='body_node' end
        end
        local poses=d.ptr(graph+0x28)
        local matrix=d.read(poses+index*64,64)
        assert(math.abs(M.float(matrix,12))+math.abs(M.float(matrix,28))+math.abs(M.float(matrix,44))<0.001
            and math.abs(M.float(matrix,60)-1)<0.001,'Unit world pose affine form')
        local position=M.vector(matrix,48)
        -- A root may be at the feet/ground; this is a display anchor, not an aim
        -- or damage change. Use a body node without any offset when available.
        if prefer_body and kind=='unit_root' then position[3]=position[3]+0.75;kind='unit_root_plus_0.75m' end
        return position,kind
    end
    function d.validate()
        for _,g in ipairs(guards) do if reader(g[1],g[2])~=g[3] then return false end end
        return true
    end
    return d
end
return M
