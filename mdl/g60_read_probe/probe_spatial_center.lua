-- Bounded scene discovery and spatial buckets; overlapping models are allowed.
local Data=require('probe_data')
local M={}
local function call(fn,...)
 if type(fn)~='function'then return nil end
 local ok,a,b=pcall(fn,...);if ok then return a,b end
end
local function squared(a,b)
 return (a[1]-b[1])^2+(a[2]-b[2])^2+(a[3]-b[3])^2
end
local function separation(c,p)
 return math.min(c.pos and squared(c.pos,p)or math.huge,c.pos1 and squared(c.pos1,p)or math.huge)
end
local function cell(p)return math.floor(p[1]/8)..':'..math.floor(p[2]/8)..':'..math.floor(p[3]/8)end
function M.new(E,emit)
 local A,W,U,B=E.Application or{},E.World or{},E.Unit or{},E.Matrix4x4 or{}
 local world,scan,cursor,clock,next_scan,last_scan=nil,nil,0,0,0,-10
 local candidates,index,seen,animated,grid,bindings,enemies={},{},{},{},{},{},{}
 local refresh,fast_refresh,prune=1,1,1
 local request,force_until=false,0
 local R={stats={queries=0,candidate_visits=0,scene_lists=0,scan_items=0,samples=0}}
 function R.reset()
  world,scan,cursor,next_scan,last_scan=nil,nil,0,0,-10
  candidates,index,seen,animated,grid,bindings,enemies={},{},{},{},{},{},{}
  refresh,fast_refresh,prune=1,1,1;request,force_until=false,0
 end
 local function valid(c)
  return c and index[c.unit]==c and call(U.alive,c.unit)==true
   and(type(U.world)~='function'or call(U.world,c.unit)==world)
 end
 local function unlink(c)
  if c.cell0 then local b=grid[c.cell0];if b then b[c]=nil;if not next(b)then grid[c.cell0]=nil end end end
  if c.cell1 and c.cell1~=c.cell0 then local b=grid[c.cell1];if b then b[c]=nil;if not next(b)then grid[c.cell1]=nil end end end
  c.cell0,c.cell1=nil,nil
 end
 local function bucket(c,key)
  if key then local b=grid[key];if not b then b={};grid[key]=b end;b[c]=true end
 end
 local function sample(c)
  R.stats.samples=R.stats.samples+1
  if not valid(c)then unlink(c);c.pos,c.pos1=nil,nil;return false end
  local p=Data.position(call(U.world_position,c.unit,0));local p1
  if c.nodes>=2 then p1=Data.position(call(U.world_position,c.unit,1))end
  local k0,k1=p and cell(p),p1 and cell(p1)
  if k0~=c.cell0 or k1~=c.cell1 then
   unlink(c);c.cell0,c.cell1=k0,k1;bucket(c,k0);if k1~=k0 then bucket(c,k1)end
  end
  c.pos,c.pos1,c.at=p,p1,clock
  return p~=nil or p1~=nil
 end
 local function demand()
  request=true;force_until=clock+.3
 end
 local function query(root,radius)
  R.stats.queries=R.stats.queries+1
  local out,visited={},{}
  for x=math.floor((root[1]-radius)/8),math.floor((root[1]+radius)/8)do
   for y=math.floor((root[2]-radius)/8),math.floor((root[2]+radius)/8)do
    for z=math.floor((root[3]-radius)/8),math.floor((root[3]+radius)/8)do
     local b=grid[x..':'..y..':'..z]
     if b then for c in pairs(b)do
      if not visited[c]then
       visited[c]=true;R.stats.candidate_visits=R.stats.candidate_visits+1
       local d=separation(c,root)
       if d<=radius*radius then out[#out+1]={c=c,d=d}end
      end
     end end
    end
   end
  end
  if #out>48 then
   table.sort(out,function(a,b)return a.d<b.d end)
   for i=#out,49,-1 do out[i]=nil end
  end
  return out
 end
 local function box(c,root)
  if not valid(c)then return nil end
  local pose,half=call(U.box,c.unit,true)
  local point=pose and Data.position(call(B.translation,pose));local extent=Data.position(half)
  if not point or not extent then return nil end
  local n=0
  for i=1,3 do if extent[i]<0 or extent[i]>100 then return nil end;n=n+extent[i]^2 end
  if n<.0001 or squared(point,root)>(2*math.sqrt(n)+3)^2 or not valid(c)then return nil end
  return point
 end
 local function remove(c)
  unlink(c);index[c.unit]=nil;seen[c.unit]=nil
  local i=c.slot;local tail=candidates[#candidates];candidates[i]=tail;candidates[#candidates]=nil
  if tail~=c then tail.slot=i end
  if c.fast_slot then
   local j=c.fast_slot;local last=animated[#animated];animated[j]=last;animated[#animated]=nil
   if last~=c then last.fast_slot=j end;c.fast_slot=nil
  end
 end
 function R.step(now,active)
  clock=now;active=active~=false
  if not active then return end
  local current=call(A.main_world);local worlds=call(A.worlds);local live=false
  for _,w in pairs(type(worlds)=='table'and worlds or{})do if w==current then live=true;break end end
  if not live then R.reset();return end
  if world~=current then R.reset();world=current end
  if type(U.num_meshes)~='function'or type(U.world_position)~='function'then return end
  if not scan and(now>=next_scan or request and now-last_scan>=.5)then
   local list=call(W.units,world)
   if type(list)=='table'and #list<=65536 then
    scan=list;cursor=#list;last_scan=now;R.stats.scene_lists=R.stats.scene_lists+1
   end
   next_scan=now+(active and 3 or 8);request=false
  end
  if scan then
   local raw,work=0,0
   -- Known scenery handles need no repeat mesh/ID/node queries. Scan the
   -- recent end first, with separate bounds on cheap lookups and engine work.
   while cursor>=1 and raw<256 and work<32 do
    local unit=scan[cursor];cursor=cursor-1;raw=raw+1
    local c=index[unit]
    if not seen[unit]then
     seen[unit]=true;work=work+1
     if call(U.alive,unit)==true then
      local meshes=call(U.num_meshes,unit)
      if type(meshes)=='number'and meshes>0 and #candidates<32768 then
       local nodes=call(U.num_scene_graph_items,unit)
       c={unit=unit,nodes=type(nodes)=='number'and nodes or 1,slot=#candidates+1}
       index[unit]=c;candidates[c.slot]=c
       if call(U.has_animation_state_machine,unit)==true then
        c.fast_slot=#animated+1;animated[c.fast_slot]=c
       end
       sample(c)
      end
     end
    elseif c and now<=force_until then sample(c);work=work+1 end
   end
   R.stats.scan_items=R.stats.scan_items+raw
   if cursor<1 then scan=nil end
  end
  local fast=math.min(active and 8 or 2,#animated)
  for _=1,fast do
   if fast_refresh>#animated then fast_refresh=1 end
   sample(animated[fast_refresh]);fast_refresh=fast_refresh+1
  end
  for _=1,math.min(active and 4 or 1,#candidates)do
   if refresh>#candidates then refresh=1 end
   sample(candidates[refresh]);refresh=refresh+1
  end
  -- Constant-size maintenance, including after a census. No full-table copy.
  for _=1,math.min(active and 4 or 2,#candidates)do
   if prune>#candidates then prune=1 end
   local c=candidates[prune]
   if c and not valid(c)then remove(c)else prune=prune+1 end
  end
 end
 function R.resolve(id,root)
  if not root or not world then return nil,'SPATIAL_WARMING'end
  local binding=bindings[id];local best,first=nil,math.huge
  -- This is equivalent to the existing 0.10 m overlap preference and avoids
  -- searching nearby scenery again for an already close, live bound model.
  if binding and sample(binding.c)then
   local d=separation(binding.c,root)
   if d<=.01 then best,first=binding.c,d end
  end
  if not best then
   for _,row in ipairs(query(root,12))do
    local c=row.c
    if sample(c)then
     local d=separation(c,root);if d<first then first,best=d,c end
    end
   end
   if binding and valid(binding.c)then
    local d=separation(binding.c,root)
    if d<=.16 and math.sqrt(d)<=math.sqrt(first)+.10 then best,first=binding.c,d end
   end
  end
  if not best or first>.16 then bindings[id]=nil;demand();return nil,'SPATIAL_NO_MATCH'end
  if not binding or binding.c~=best or clock-binding.last>.25 then
   binding={c=best,seen=0,last=-1};bindings[id]=binding
  end
  if clock>binding.last then binding.seen=binding.seen+1;binding.last=clock end
  if binding.seen<3 then return nil,'SPATIAL_CONFIRMING'end
  local point=box(best,root)
  if not point then return nil,'SPATIAL_BOX_UNAVAILABLE'end
  return point,'UNIT_SPATIAL_BOX_CENTER'
 end
 function R.forget_enemy(key)enemies[key]=nil end
 function R.enemy_position(key,root,network_id)
  local c=enemies[key]
  if c and not valid(c)then enemies[key]=nil;c=nil end
  if not c and network_id and bindings[network_id]and valid(bindings[network_id].c)then c=bindings[network_id].c end
  if not c and root then
   local best=1
   for _,row in ipairs(query(root,2))do
    if sample(row.c)then local d=separation(row.c,root);if d<best then best,c=d,row.c end end
   end
   if not c then demand()end
  end
  if not c or not sample(c)then return nil end
  local origin=c.pos1 or c.pos
  local point=origin and box(c,origin)
  if point then enemies[key]=c end
  return point
 end
 return R
end
return M
