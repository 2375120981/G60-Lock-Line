-- Pure segment clipping. A segment is accepted by intersection, never by an
-- endpoint-in-screen test; both endpoints may be offscreen.
local M={}
local function lerp(a,b,t) return {a[1]+(b[1]-a[1])*t,a[2]+(b[2]-a[2])*t,a[3]+(b[3]-a[3])*t} end
function M.near_clip(a,b,position,forward,near)
    local function depth(p)
        return (p[1]-position[1])*forward[1]+(p[2]-position[2])*forward[2]+(p[3]-position[3])*forward[3]
    end
    local da,db=depth(a),depth(b)
    if da<near and db<near then return nil end
    if da<near then a=lerp(a,b,(near-da)/(db-da))
    elseif db<near then b=lerp(a,b,(near-da)/(db-da)) end
    return a,b
end
function M.rect_clip(a,b,width,height)
    local dx,dy=b[1]-a[1],b[2]-a[2]
    local p,q={-dx,dx,-dy,dy},{a[1],width-a[1],a[2],height-a[2]}
    local first,last=0,1
    for i=1,4 do
        if p[i]==0 then if q[i]<0 then return nil end
        else
            local ratio=q[i]/p[i]
            if p[i]<0 then first=math.max(first,ratio) else last=math.min(last,ratio) end
            if first>last then return nil end
        end
    end
    return {a[1]+dx*first,a[2]+dy*first},{a[1]+dx*last,a[2]+dy*last}
end
function M.screen_quad(a,b,width)
    local dx,dy=b[1]-a[1],b[2]-a[2]
    local length=math.sqrt(dx*dx+dy*dy)
    if length<0.001 then return nil end
    local x,y=-dy/length*width/2,dx/length*width/2
    return {{a[1]-x,a[2]-y},{b[1]-x,b[2]-y},{b[1]+x,b[2]+y},{a[1]+x,a[2]+y}}
end
function M.triangle_clip(a,b,c,width,height)
    local polygon={a,b,c}
    for _,edge in ipairs({{1,0,1},{1,width,-1},{2,0,1},{2,height,-1}}) do
        local input=polygon;polygon={}
        if #input==0 then break end
        local axis,bound,sign=edge[1],edge[2],edge[3]
        local previous=input[#input]
        local previous_in=(previous[axis]-bound)*sign>=0
        for _,point in ipairs(input) do
            local inside=(point[axis]-bound)*sign>=0
            if inside~=previous_in then
                local t=(bound-previous[axis])/(point[axis]-previous[axis])
                polygon[#polygon+1]={previous[1]+(point[1]-previous[1])*t,previous[2]+(point[2]-previous[2])*t}
            end
            if inside then polygon[#polygon+1]=point end
            previous,previous_in=point,inside
        end
    end
    local triangles={}
    for i=2,#polygon-1 do triangles[#triangles+1]={polygon[1],polygon[i],polygon[i+1]} end
    return triangles
end
return M
