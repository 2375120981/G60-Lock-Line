local Data=require('probe_data')
local Lines=require('probe_lines')
local Config=require('probe_config')
local Center=require('probe_center')
local Squad=require('probe_squad')
local EnemyPool=require('probe_enemy_pool')
local Estimator=require('probe_estimator')
local M={}
local function call(fn,...)
    if type(fn)~='function' then return false,'API_ABSENT' end
    return pcall(fn,...)
end
local function id(v) return type(v)=='number' and v==math.floor(v) and v>=0 and v<32767 end
function M.new(E,emit,build,settings)
    local A,N,G=E.Application or{},E.Network or{},E.GameSession or{}
    local time,next_scan,tokens,session,peer,baseline=0,0,0,nil,nil,true
    local baseline_warm_until=0
    local objects,order,cursor,owned={}, {},1,{}
    local hub,epoch,next_hub=nil,nil,0
    local in_mission=false
    local lines=Lines.new(E,emit,settings)
    local center=Center.new(E,emit)
    local squad=Squad.new(E,emit)
    local enemies=EnemyPool.new(E,center,emit)
    local estimator=Estimator.new(Config.estimation)
    local R={stats={reads=0,errors=0,scans=0,snapshots=0,observed=0,links=0},stopped=false}
    local function reset(reason)
        objects,order,cursor,owned={}, {},1,{};session=nil;peer=nil;baseline=true;next_scan=0
        lines.clear();emit('RESET',reason)
        center.reset();squad.reset();enemies.reset(epoch);estimator:reset()
    end
    local function add(value,new,source)
        if not id(value) then return end
        if objects[value] then return objects[value] end
        if #order>=2112 then return end
        local entry={id=value,next_read=time,until_time=new and time+.6 or 0,created_at=time,is_new=new,attempts=0}
        objects[value]=entry;order[#order+1]=value
        emit(new and 'NEW_OBJECT' or 'BASELINE','network_id='..value..' source='..(source or 'local_owned'))
        return entry
    end
    local function mission()
        local D=rawget(_G,'HD2Data')
        local ok,ready=call(type(D)=='table' and D.ready)
        if not ok or ready~=true then
            in_mission=false
            if hub then hub=nil;epoch=nil;reset('Hub stopped') end
            return
        end
        if hub~=D then hub=D;epoch=nil;reset('Hub interface changed') end
        local good,m=call(D.mission)
        if good and type(m)=='table' then in_mission=m.in_mission==true end
        if good and type(m)=='table' and m.epoch~=epoch then epoch=m.epoch;reset('mission epoch='..tostring(epoch)) end
    end
    local function scan()
        local good,s=call(N.game_session);local ok,p=call(N.peer_id)
        if not good or s==nil or not ok or p==nil then
            if session then reset('session lost') end;return
        end
        if session~=s or peer~=p then reset('session/peer changed');session=s;peer=p end
        local found,ids=call(G.objects_owned_by,session,peer)
        if not found or type(ids)~='table' then return end
        local now={};local n=0;local added={}
        if baseline then baseline_warm_until=time+.75 end
        for _,value in pairs(ids) do
            if id(value) and not now[value] then
                now[value]=true;n=n+1
                if not owned[value] then added[#added+1]=value end
            end
            if n>=512 then break end
        end
        local remotes=squad.scan(session,peer,time)
        for value,owner in pairs(remotes)do
            if not now[value]then
                now[value]=owner;n=n+1
                if not owned[value]then added[#added+1]=value end
            end
        end
        table.sort(added,function(a,b)return a>b end)
        for _,value in ipairs(added)do
            local e=add(value,not baseline,now[value]==true and 'local_owned' or 'remote_owned')
            if e then e.locally_owned=now[value]==true end
        end
        for value,e in pairs(objects)do
            if now[value]~=nil then e.locally_owned=now[value]==true end
        end
        for value in pairs(owned) do
            if not now[value] then
                emit('GONE','network_id='..value);objects[value]=nil
            end
        end
        for value,e in pairs(objects)do
            if not now[value] and not e.source_at and e.sampled and (e.target_until or 0)<time then objects[value]=nil end
        end
        local keep={};for _,value in ipairs(order)do if objects[value]then keep[#keep+1]=value end end
        order=keep;if cursor>#order then cursor=1 end
        owned=now;baseline=false;R.stats.scans=R.stats.scans+1;R.stats.observed=n
    end
    local function source_live(e) return not e.terminal and e.source_at and time-e.source_at<=Config.source_max_age end
    local function pick()
        local best,urgent
        for _,value in ipairs(order)do
            local e=objects[value]
            if e and e.is_new and not e.sampled and time>=e.next_read
                and (not urgent or (e.locally_owned==true and urgent.locally_owned~=true)
                    or e.locally_owned==urgent.locally_owned and (e.created_at>urgent.created_at
                        or e.created_at==urgent.created_at and e.id>urgent.id))then urgent=e end
        end
        -- Only identified G60s and their explicitly referenced targets get fast reads.
        for _,value in ipairs(order) do
            local e=objects[value]
            if e and (source_live(e) or (e.target_until or 0)>=time)
                and time>=e.next_read and (not best or e.next_read<best.next_read) then best=e end
        end
        if urgent and (not best or best.next_read>=time-.025)then return urgent,false end
        if best then return best,true end
        if urgent then return urgent,false end
        -- New objects get one immediate classification before baseline work.
        for _,value in ipairs(order) do
            local e=objects[value]
            if e and e.attempts<3 and e.until_time>time and time>=e.next_read then return e,false end
        end
        for _=1,#order do
            if cursor>#order then cursor=1 end
            local e=objects[order[cursor]];cursor=cursor+1
            if e and not e.sampled and time>=e.next_read then return e,false end
        end
    end
    local function read(e,fast)
        local same,current=call(N.game_session)
        if not same or current~=session then reset('session changed before read');return end
        local good,exists=call(G.game_object_exists,session,e.id)
        if not good or exists~=true then objects[e.id]=nil;return end
        e.next_read=time+(fast and Config.target_interval or .1);e.sampled=true;e.attempts=e.attempts+1
        local ok,f=call(G.game_object_field_batched,session,e.id,{})
        R.stats.reads=R.stats.reads+1
        local fallback_root
        if not ok or type(f)~='table'then
            -- A referenced target can expose its named position even when a
            -- complete batched snapshot is unavailable on this peer.
            if (e.target_until or 0)>=time then
                local good,p=call(G.game_object_field,session,e.id,'position')
                if good then fallback_root=Data.position(p)end
            end
            if fallback_root then f={}
            else
                R.stats.errors=R.stats.errors+1;e.source_at=nil;e.position=nil
                e.read_reason='BATCH_UNAVAILABLE'
                return
            end
        end
        local source=Data.g60(f,build)
        if source then
            if source.terminal and Config.early_terminal_slot3 then
                if not e.terminal then emit('G60_END_CANDIDATE','network_id='..e.id..' slot3=true') end
                e.terminal=true;e.source_at=nil;e.position=nil;e.position_at=nil;e.target=nil
                e.until_time=0;e.target_until=0
                emit('SNAPSHOT',{id=e.id,fields=f,fast=fast})
                R.stats.snapshots=R.stats.snapshots+1
                return
            end
            if e.terminal then return end
            if not e.source_at then emit('G60_TRACK','network_id='..e.id..' target='..tostring(source.target)..' queue_ms='..math.floor((time-e.created_at)*1000)..' locally_owned='..tostring(e.locally_owned)) end
            e.source_at=time;e.position=source.position;e.target=source.target;e.next_read=time+Config.source_interval
            if e.last_target~=source.target then
                emit('TARGET_CHANGE','g60='..e.id..' target='..tostring(source.target));e.last_target=source.target
            end
            if source.target~=nil then
                local target=add(source.target,false,'g60_target_ref')
                if target then target.target_until=time+.35;if not target.position then target.next_read=math.min(target.next_read,time) end end
            end
        else
            e.source_at=nil;e.target=nil
            local root,kind=Data.target(f,build)
            if not root and (e.target_until or 0)>=time then
                root=fallback_root
                if not root then
                    local good,p=call(G.game_object_field,session,e.id,'position')
                    if good then root=Data.position(p)end
                end
                if root then kind='NETWORK_NAMED_POSITION'end
            end
            if root then e.read_reason=nil else e.read_reason=kind end
            e.position=nil;e.centered=false
            if root and (e.target_until or 0)>=time then
                enemies.seed(e.id,root,time)
                local point,why=center.resolve(session,e.id,root)
                e.centered=point~=nil
                e.center_kind=why
                e.position=point or (Config.center_fallback_to_network and root or nil)
                e.endpoint_kind=point and 'UNIT_BOX_CENTER' or kind
                if e.center_reason~=why then
                    e.center_reason=why
                    emit('TARGET_CENTER','target='..e.id..' result='..why..' fallback='..tostring(not e.centered and Config.center_fallback_to_network))
                end
            end
        end
        e.position_at=e.position and time or nil
        -- Caller logs raw data under a budget; vectors are consumed this frame.
        emit('SNAPSHOT',{id=e.id,fields=f,fast=fast})
        R.stats.snapshots=R.stats.snapshots+1
    end
    local function present()
        local rows={};local live={}
        local candidates,candidate_map
        local display={}
        for _,value in ipairs(order)do
            local e=objects[value]
            if e and source_live(e)and e.position then display[#display+1]=value end
        end
        table.sort(display,function(a,b)
            local x,y=objects[a],objects[b]
            if x and y and (x.locally_owned==true)~=(y.locally_owned==true) then return x.locally_owned==true end
            return a<b
        end)
        for _,value in ipairs(display)do
            local e=objects[value]
            if e and source_live(e) and e.position then
                local good,exists=call(G.game_object_exists,session,e.id)
                if good and exists==true then
                    local row={id=e.id,from=e.position,target=e.target,locally_owned=e.locally_owned}
                    if row.target~=nil then
                        local target=objects[row.target]
                        local ok,alive=call(G.game_object_exists,session,row.target)
                        if not ok or alive~=true then row.target=nil
                        elseif target and target.position_at and time-target.position_at<=Config.target_max_age and not target.source_at then
                            row.to=target.position
                            row.centered=target.centered
                            row.center_kind=target.center_kind
                        end
                    end
                    live[e.id]=true
                    if e.locally_owned==false and not row.to then
                        if not candidates then candidates,candidate_map=enemies.snapshot(time)end
                        local guess,reason=e.estimated_candidate,e.estimate_reason
                        if time>=(e.next_estimate or 0)or(guess and not candidate_map[guess.key])then
                            guess,reason=estimator:choose({key=e.id,from=e.position,remote_active=true,
                                locally_owned=false,terminal=e.terminal},candidates,time,time)
                            e.estimated_candidate=guess;e.next_estimate=time+.1
                        end
                        local current=guess and candidate_map[guess.key]
                        row.estimate_reason=reason
                        if current then
                            row.to=current.point;row.target=current.id;row.estimated=true
                            row.centered=true;row.center_kind='ESTIMATED_MODEL_CENTER'
                        end
                        if e.estimate_reason~=reason then
                            e.estimate_reason=reason
                            emit('TARGET_ESTIMATE','g60='..e.id..' reason='..tostring(reason)..' target='..tostring(current and current.key))
                        end
                    else estimator:forget(e.id);e.estimated_candidate=nil;e.next_estimate=nil end
                    local missing
                    if not row.to then
                        local target=e.target and objects[e.target]
                        missing=not e.target and 'NO_NETWORK_TARGET'
                            or target and target.read_reason or 'WAIT_TARGET_POSITION'
                    end
                    if missing~=e.missing_reason then
                        e.missing_reason=missing
                        if missing then emit('TARGET_WAIT','g60='..e.id..' locally_owned='..tostring(e.locally_owned)
                            ..' target='..tostring(e.target)..' reason='..missing)end
                    end
                    rows[#rows+1]=row;if #rows>=4 then break end
                end
            end
        end
        estimator:prune(live)
        local state,count=lines.draw(rows)
        R.stats.links=count
    end
    function R.update(dt)
        if R.stopped then return end
        time=time+dt
        if time>=next_hub then next_hub=time+.25;mission() end
        if time>=next_scan then next_scan=time+.1;scan() end
        local active=false;for _,e in pairs(objects)do if source_live(e)then active=true;break end end
        local fresh=false;for _,e in pairs(objects)do if e.is_new and not e.sampled then fresh=true;break end end
        if session and (in_mission or active)then center.step(time,active)end
        local burst=active or fresh or time<baseline_warm_until
        tokens=math.min(2,tokens+dt*(burst and 64 or 12))
        for _=1,(burst and 2 or 1)do
            if tokens<1 then break end
            local entry,fast=pick();if not entry then break end
            tokens=tokens-1;read(entry,fast)
        end
        local tracking=false
        for _,e in pairs(objects)do if source_live(e)then tracking=true;break end end
        enemies.update(time,session,tracking,epoch)
        present()
    end
    function R.set_settings(values)lines.set_settings(values)end
    function R.shutdown()
        if R.stopped then return end
        R.stopped=true;objects={};order={};owned={};center.reset();squad.reset();enemies.shutdown();estimator:reset();lines.shutdown()
    end
    return R
end
return M
