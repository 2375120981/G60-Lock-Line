-- GameSession snapshot decoders for the recorded 46805 build only.
local M={BUILD='stingray:46805 437a3d445f9df7662b60086ac8ae3c65b5c95da6'}
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<1e7 end
function M.position(v)
    if type(v)=='table' then
        local x,y,z=v.x or v[1],v.y or v[2],v.z or v[3]
        if finite(x) and finite(y) and finite(z) then return {x,y,z} end
    elseif type(v)=='userdata' then
        local ok,s=pcall(tostring,v)
        if ok then
            local a,b,c=s:match('^Vector3%(([^,]+),%s*([^,]+),%s*([^%)]+)%)$')
            local x,y,z=tonumber(a),tonumber(b),tonumber(c)
            if finite(x) and finite(y) and finite(z) then return {x,y,z} end
        end
    end
end
function M.g60(f,build)
    if build~=M.BUILD or type(f)~='table' then return nil end
    if f[44]~=12 or f[45]~=24 or type(f[49])~='boolean'
        or type(f[52])~='number' or type(f[56])~='number' then return nil end
    local pos=M.position(f[18]);if not pos or not M.position(f[29]) then return nil end
    local target=f[52]
    if target~=math.floor(target) or target<0 or target>=32767 then target=nil end
    -- Slot 3 becomes true near the end of all three recorded throws while
    -- IDs remain readable. Experimental early cleanup signal for this build.
    return {position=pos,target=target,terminal=f[3]==true}
end
function M.target(f,build)
    if build~=M.BUILD or type(f)~='table' then return nil,'UNSUPPORTED_BUILD' end
    -- Two target snapshot shapes are present in both recorded throw tests.
    -- Use the changing outer position, never a nested spawn position.
    if type(f[44])=='table' and M.position(f[44][8]) and M.position(f[50])
        and type(f[48])=='number' and type(f[49])=='number' then
        local p=M.position(f[55]);if p then return p,'NETWORK_44_55' end
    end
    if type(f[51])=='table' and M.position(f[51][3])
        and type(f[54])=='number' and type(f[55])=='number' and type(f[56])=='number' then
        local p=M.position(f[57]);if p then return p,'NETWORK_51_57' end
    end
    return nil,'TARGET_POSITION_UNSUPPORTED'
end
return M
