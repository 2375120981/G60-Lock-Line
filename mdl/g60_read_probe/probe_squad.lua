-- Enumerate actual session peers; never brute-force network object IDs.
local M={}
local function call(fn,...)
 if type(fn)~='function'then return nil end
 local ok,v=pcall(fn,...);if ok then return v end
end
function M.new(E,emit)
 local N,G=E.Network or{},E.GameSession or{}
 local session,next_scan,cache,last=nil,0,{},nil
 local R={}
 function R.reset()session,next_scan,cache,last=nil,0,{},nil end
 function R.scan(s,mine,now)
  if s~=session then R.reset();session=s end
  if now>=next_scan then
   next_scan=now+.25
   local peers,seen={}, {[tostring(mine)]=true}
   for _,list in ipairs({call(G.peers,s)or{},call(N.connections)or{}})do
    for _,p in pairs(type(list)=='table'and list or{})do
     local key=tostring(p)
     if p~=nil and not seen[key]and #peers<3 then seen[key]=true;peers[#peers+1]=p end
    end
   end
   local next_cache={}
   for _,p in ipairs(peers)do
    local key=tostring(p);local ids=call(G.objects_owned_by,s,p)
    if type(ids)=='table'then
     local values={};local count=0
     for _,id in pairs(ids)do
      if type(id)=='number'and id==math.floor(id)and id>=0 and id<32767 and not values[id]then
       values[id]=true;count=count+1;if count>=512 then break end
      end
     end
     next_cache[key]={ids=values,at=now}
    elseif cache[key]and now-cache[key].at<=.75 then next_cache[key]=cache[key]end
   end
   cache=next_cache
   local total=0;for _ in pairs(cache)do total=total+1 end
   if total~=last then last=total;if emit then emit('SQUAD_SCAN','remote_peers='..total)end end
  end
  local out={}
  for owner,c in pairs(cache)do
   if now-c.at<=.75 then for id in pairs(c.ids)do out[id]=owner end end
  end
  return out
 end
 return R
end
return M
