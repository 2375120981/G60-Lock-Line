-- Marker geometry is separate from target discovery and camera projection.
-- Add future styles here; visual-style.json selects their sizes and appearance.
local M={}
function M.estimated_ring(spec)
    return {style='ring',radius_px=32,width_px=(spec or {}).width_px or 1.5,segments=64,
        world_cross_half_m=spec and spec.style=='world_cross' and (spec.half_size_m or 0.2) or nil}
end
function M.is_screen(spec)
    return spec and (spec.style=='ring' or spec.style=='cross_frame' or spec.style=='spear_triangle')
end
function M.world(spec,p)
    spec=spec or {style='world_cross',half_size_m=0.2}
    local result={}
    if spec.style=='world_cross' then
        local size=spec.half_size_m or 0.2
        for axis=1,3 do
            local a,b={p[1],p[2],p[3]},{p[1],p[2],p[3]}
            a[axis],b[axis]=a[axis]-size,b[axis]+size
            result[#result+1]={from=a,to=b,marker=true}
        end
    end
    return result
end
function M.screen(spec,p)
    local result={}
    if spec and spec.style=='ring' then
        local radius,n=spec.radius_px or 6,spec.segments or 24
        for i=0,n-1 do
            local a,b=i*2*math.pi/n,(i+1)*2*math.pi/n
            result[#result+1]={from={p[1]+radius*math.cos(a),p[2]+radius*math.sin(a)},
                to={p[1]+radius*math.cos(b),p[2]+radius*math.sin(b)}}
        end
    elseif spec and spec.style=='spear_triangle' then
        -- Screenshot recreation, not an extracted Spear texture. Screen GUI
        -- coordinates increase upward. Center the equilateral triangle's
        -- centroid on the real target and soften its three corners.
        local x,y=p[1],p[2]
        local r=spec.half_size_px or 10
        local h=r*math.sqrt(3)
        local corners={{x,y+2*h/3},{x-r,y-h/3},{x+r,y-h/3}}
        local path={}
        local trim=math.min(spec.corner_radius_px or 1.5,r)
        for i=1,3 do
            local c,prev,next=corners[i],corners[(i+1)%3+1],corners[i%3+1]
            local t=trim/(2*r)
            local a={c[1]+(prev[1]-c[1])*t,c[2]+(prev[2]-c[2])*t}
            local b={c[1]+(next[1]-c[1])*t,c[2]+(next[2]-c[2])*t}
            path[#path+1]=a
            for step=1,4 do
                local u=step/4
                path[#path+1]={(1-u)^2*a[1]+2*(1-u)*u*c[1]+u^2*b[1],
                    (1-u)^2*a[2]+2*(1-u)*u*c[2]+u^2*b[2]}
            end
        end
        for i=1,#path do
            result[#result+1]={from=path[i],to=path[i%#path+1]}
        end
    elseif spec and spec.style=='cross_frame' then
        local x,y=p[1],p[2]
        local r,gap=spec.half_size_px or 20,spec.gap_px or 6
        local function stroke(ax,ay,bx,by)
            result[#result+1]={from={ax,ay},to={bx,by}}
        end
        -- A closed square, with four inward ticks and an empty center.
        stroke(x-r,y-r,x+r,y-r)
        stroke(x+r,y-r,x+r,y+r)
        stroke(x+r,y+r,x-r,y+r)
        stroke(x-r,y+r,x-r,y-r)
        stroke(x-r,y,x-gap,y)
        stroke(x+gap,y,x+r,y)
        stroke(x,y-r,x,y-gap)
        stroke(x,y+gap,x,y+r)
    end
    return result
end
return M
