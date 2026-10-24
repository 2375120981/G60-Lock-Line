-- Crossed, double-sided ribbons in world space. No camera/FOV modifications.
local M = {}
local function cross(a,b)
    return {a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]}
end
local function offset(p,n,w)
    return {p[1]+n[1]*w,p[2]+n[2]*w,p[3]+n[3]*w}
end
function M.ribbon(segment,width)
    local a,b=segment.from,segment.to
    local direction={b[1]-a[1],b[2]-a[2],b[3]-a[3]}
    local length=math.sqrt(direction[1]^2+direction[2]^2+direction[3]^2)
    if length<0.00001 then return {} end
    for i=1,3 do direction[i]=direction[i]/length end
    -- A reference axis that is never nearly parallel to the segment.
    local normal=cross(direction,math.abs(direction[3])<0.9 and {0,0,1} or {1,0,0})
    local norm=math.sqrt(normal[1]^2+normal[2]^2+normal[3]^2)
    for i=1,3 do normal[i]=normal[i]/norm end
    local second=cross(direction,normal)
    local triangles={}
    for _,axis in ipairs({normal,second}) do
        local am,ap=offset(a,axis,-width/2),offset(a,axis,width/2)
        local bm,bp=offset(b,axis,-width/2),offset(b,axis,width/2)
        -- Both windings, so the ribbon is visible from either side.
        triangles[#triangles+1]={am,bm,bp}
        triangles[#triangles+1]={am,bp,ap}
        triangles[#triangles+1]={bp,bm,am}
        triangles[#triangles+1]={ap,bp,am}
    end
    return triangles
end
return M
