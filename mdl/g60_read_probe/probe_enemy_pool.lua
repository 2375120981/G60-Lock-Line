-- Known enemies only: Hub enemy events or explicit G60 target references.
-- Event positions seed live mesh tracking; never interpret entity/unit IDs as handles.
local Data=require('probe_data')
local M={}
local function call(fn,...)
 if type(fn)~='function'then return nil end
 local ok,v=pcall(fn,...);if ok then return v end
end
local function object(v)return type(v)=='table'or type(v)=='userdata'end
local function valid_id(v)return type(v)=='number'and v==math.floor(v)and v>=0 and v<32767 end
function M.new(E,center,emit)
 local G=E.GameSession or{}
 local records,by_network,subscriptions,hub={}, {},{},nil
 local clock,epoch,next_tick,next_hub,cursor=0,nil,0,0,1
 local dead_network={}
 local order={}
 local Rstats={max_records_per_update=0}
 local R={stats=Rstats};local last_status,last_events
 local function status(s)
  R.status=s
  if s~=last_status then last_status=s;if emit then emit('ESTIMATE_POOL',s)end end
 end
 local function remove(key)
  local r=records[key]
  if r and r.network and by_network[r.network]==key then by_network[r.network]=nil end
  if r then
   local tail=order[#order];order[r.slot]=tail;order[#order]=nil
   if tail~=key then records[tail].slot=r.slot end
  end
  records[key]=nil;center.forget_enemy(key)
 end
 local function clear_records()
  for k in pairs(records)do center.forget_enemy(k)end
  records,by_network,cursor={}, {},1;dead_network={};order={}
 end
 local function unsubscribe()
  for _,s in ipairs(subscriptions)do call(s.unsubscribe,s)end
  subscriptions={};hub=nil
 end
 function R.reset(e)clear_records();epoch=e;next_tick=0;next_hub=0 end
 function R.shutdown()unsubscribe();clear_records()end
 local function add(key,network)
  if records[key]then return records[key]end
  if #order>=64 then return nil end
  local r={key=key,network=network,slot=#order+1};records[key]=r;order[r.slot]=key
  r.view={key=key,id=network,alive=true,priority=0}
  if network then by_network[network]=key end
  return r
 end
 function R.seed(id,root,now)
  if not valid_id(id)or not root or dead_network[id]then return end
  local key=by_network[id]or('network:'..id);local r=add(key,id)
  if r then r.root=root;r.root_at=now;r.until_time=now+2 end
 end
 local function observe(e)
  if type(e)~='table'or e.enemy~=true or(epoch~=nil and e.mission~=nil and epoch~=e.mission)then return end
  if e.entity_id==nil then return end
  local network=valid_id(e.network_id)and e.network_id or nil
  if network and dead_network[network]then
   if e.event=='entity_spawned'and e.entity_id~=dead_network[network]then dead_network[network]=nil else return end
  end
  local key=network and by_network[network]or('hub:'..tostring(e.entity_id))
  local r=add(key,network);if not r then return end
  r.entity=e.entity;r.entity_id=e.entity_id;r.hub_known=true
  if network then r.network=network;by_network[network]=key end
  local point=Data.position(e.position)
  if not point and object(e.entity)then point=Data.position(call(e.entity.position,e.entity))end
  if point then r.root=point;r.root_at=clock end
  if type(e.health)=='number'and e.health<=0 then
   if network then dead_network[network]=e.entity_id end;remove(key)
  end
 end
 local function died(e)
  if type(e)~='table'or(epoch~=nil and e.mission~=nil and epoch~=e.mission)then return end
  if valid_id(e.network_id)then dead_network[e.network_id]=e.entity_id or true end
  local keys={}
  for k,r in pairs(records)do
   if(e.entity_id~=nil and r.entity_id==e.entity_id)or(e.network_id~=nil and r.network==e.network_id)then
    if r.network then dead_network[r.network]=e.entity_id or true end;keys[#keys+1]=k
   end
  end
  for _,k in ipairs(keys)do remove(k)end
 end
 function R.update(now,session,active,current_epoch)
  local dt=math.max(0,math.min(.05,now-clock));clock=now
  if epoch~=current_epoch then R.reset(current_epoch)end
  -- Keep only lightweight enemy identity observations while idle. Geometry
  -- and scene enumeration still start only while a G60 is active.
  if now>=next_hub then
   next_hub=now+.25
   local D=rawget(_G,'HD2Data')
   if type(D)~='table'or call(D.ready)~=true then
    if hub then unsubscribe();clear_records()end
   elseif D~=hub then
    unsubscribe();hub=D
    for _,spec in ipairs({{'entity_spawned',observe},{'entity_damaged',observe},{'entity_died',died}})do
     local sub=call(D.on,spec[1],spec[2],{owner='g60_read_probe',id='estimate_'..spec[1]})
     if object(sub)then subscriptions[#subscriptions+1]=sub end
    end
   end

  end
  if not session or not active then return end
  local budget=math.max(2,math.min(8,math.ceil(dt*240)))
  local count=math.min(budget,#order);Rstats.max_records_per_update=math.max(Rstats.max_records_per_update,count)
  for _=1,count do
   if cursor>#order then cursor=1 end
   local key=order[cursor];cursor=cursor+1;local r=key and records[key]
   if not r then break end
   local expired=not r.hub_known and now>(r.until_time or 0)
   if r.network and call(G.game_object_exists,session,r.network)~=true then expired=true end
   if object(r.entity)and call(r.entity.is_valid,r.entity)==false then expired=true end
   if expired then remove(key)
   elseif active or(r.root_at and now-r.root_at<=.35)then
    local root=r.root_at and now-r.root_at<=.35 and r.root or nil
    if not root and not r.bound and r.network then
     root=Data.position(call(G.game_object_field,session,r.network,'position'))
     if root then r.root=root;r.root_at=now end
    end
    local point=center.enemy_position(key,root,r.network)
    if point then r.point=point;r.at=now;r.bound=true else r.point=nil;r.at=nil;r.bound=false end
   end
  end
  if now>=next_tick then
   next_tick=now+1
   local n=0;for _,r in pairs(records)do if r.at and now-r.at<=.35 then n=n+1 end end
   status('fresh='..n..' observed='..#order..' hub='..tostring(hub~=nil))
  end
 end
 function R.snapshot(now)
  local list,map={},{}
  for key,r in pairs(records)do
   if r.point and r.at and now-r.at<=.35 then
    local e=r.view;e.id=r.network or r.entity_id;e.point=r.point
    list[#list+1]=e;map[key]=e
   end
  end
  table.sort(list,function(a,b)return a.key<b.key end)
  return list,map
 end
 return R
end
return M
