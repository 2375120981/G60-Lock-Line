-- Pure local inference, kept separate from authoritative native selections.
local Scope=require('g60line.observation_scope')
local M={}
local function delta(a,b) return {a[1]-b[1],a[2]-b[2],a[3]-b[3]} end
local function dot(a,b) return a[1]*b[1]+a[2]*b[2]+a[3]*b[3] end
local function length(v) return math.sqrt(dot(v,v)) end
local function copy(p) return {p[1],p[2],p[3]} end
function M.new(config)
    local tracks,enemy_history,last_enemy_snapshot={}, {},nil
    local api={}
    function api:forget(key) tracks[key]=nil end
    function api:reset() tracks={};enemy_history={};last_enemy_snapshot=nil end
    function api:prune(seen) for key in pairs(tracks) do if not seen[key] then tracks[key]=nil end end end
    function api:choose(row,enemies,now,sampled_at)
        local key=row.entity_key or row.key
        if not row.remote_active or row.locally_owned~=false or row.terminal
            or not Scope.valid_position(row.from) then self:forget(key);return nil,'inactive' end
        local track=tracks[key]
        if not track then track={samples={}};tracks[key]=track end
        if row.remote_phase~=2 and row.remote_phase~=3 and row.remote_phase~=4 then
            self:forget(key);return nil,'inactive'
        end
        -- Uncertainty changes the estimate reason, not its visibility. Keep only
        -- an enemy identity here; the controller rechecks life, generation and
        -- current pose before rendering every frame, including retained guesses.
        local samples=track.samples
        local last=samples[#samples]
        if last and now-last.time>0.35 then samples={};track.samples=samples;track.pending=nil;last=nil end
        if not last or now-last.time>=config.sample_interval_s then
            samples[#samples+1]={point=copy(row.from),time=now}
            if #samples>4 then table.remove(samples,1) end
        end
        -- A recent heading is useful even before strict pursuit can be proven.
        local heading,heading_speed
        local reference=samples[#samples]
        local heading_dt=reference and now-reference.time or 0
        if reference and heading_dt>0.001 then
            heading=delta(row.from,reference.point)
        elseif #samples>=2 then
            reference=samples[#samples-1];heading_dt=now-reference.time
            heading=delta(row.from,reference.point)
        end
        if heading and heading_dt>0 then
            for i=1,3 do heading[i]=heading[i]/heading_dt end
            heading_speed=length(heading)
            if heading_speed<config.minimum_speed_m_s or heading_speed>config.maximum_speed_m_s then heading=nil end
        else heading=nil end
        local fresh=sampled_at and now-sampled_at<=config.candidate_freshness_s
        local fallback
        if fresh then
            for _,enemy in ipairs(enemies or {}) do
                if enemy.alive and Scope.valid_position(enemy.point) then
                    local direction=delta(enemy.point,row.from)
                    local distance=length(direction)
                    if distance>0.2 and distance<=config.candidate_radius_m then
                        if track.target and track.target.key==enemy.key then track.target=enemy end
                        local proximity=1-distance/config.candidate_radius_m
                        local score=0.95*proximity+0.05*(enemy.priority or 0)
                        if heading then
                            local alignment=math.max(-1,math.min(1,dot(direction,heading)/(distance*heading_speed)))
                            score=0.65*(alignment+1)/2+0.30*proximity+0.05*(enemy.priority or 0)
                        end
                        local tied=fallback and math.abs(score-fallback.score)<1e-9
                        if not fallback or score>fallback.score+1e-9 or tied and
                            (track.target and enemy.key==track.target.key or
                             (not track.target or fallback.enemy.key~=track.target.key) and enemy.key<fallback.enemy.key) then
                            fallback={enemy=enemy,score=score}
                        end
                    end
                end
            end
        end
        local function select(candidate,reason,score)
            if not candidate then track.pending=nil;return track.target,reason end
            if not track.target or track.target.key==candidate.key then
                track.pending=nil;track.target=candidate;return candidate,reason,score
            end
            -- Re-evaluate all fresh candidates even when intent is uncertain.
            -- Confirm switches without blanking the currently displayed line.
            if track.pending~=candidate.key then track.pending=candidate.key;track.since=now end
            if now-track.since<config.confirm_s then return track.target,'uncertain_confirming',nil,candidate end
            track.pending=nil;track.target=candidate;return candidate,reason,score
        end
        local function uncertain(reason)
            return select(fallback and fallback.enemy,
                (track.target or fallback) and 'uncertain_'..reason or reason,fallback and fallback.score)
        end
        if not fresh then return uncertain('stale_candidates') end
        if sampled_at~=last_enemy_snapshot then
            local fresh={}
            for _,enemy in ipairs(enemies or {}) do
                if Scope.valid_position(enemy.point) then
                    local old=enemy_history[enemy.key]
                    local motion={0,0,0}
                    if old and sampled_at>old.time and sampled_at-old.time<1 then
                        motion=delta(enemy.point,old.point)
                        for i=1,3 do motion[i]=motion[i]/(sampled_at-old.time) end
                    end
                    fresh[enemy.key]={point=copy(enemy.point),time=sampled_at,velocity=motion}
                end
            end
            enemy_history=fresh;last_enemy_snapshot=sampled_at
        end
        if row.remote_phase~=4 then return uncertain('searching') end
        if #samples<3 or samples[#samples].time-samples[1].time<config.minimum_history_s then
            return uncertain('collecting_motion')
        end
        local latest,previous=samples[#samples],samples[#samples-1]
        local dt=latest.time-previous.time
        local velocity=delta(latest.point,previous.point)
        for i=1,3 do velocity[i]=velocity[i]/dt end
        local speed=length(velocity)
        if speed<config.minimum_speed_m_s or speed>config.maximum_speed_m_s then
            return uncertain('motion_unreliable')
        end
        local earlier=samples[#samples-2]
        local old=delta(previous.point,earlier.point);local old_speed=length(old)
        if old_speed<0.05 or dot(old,velocity)/(old_speed*speed)<0.75 then
            return uncertain('turning_or_orbiting')
        end
        local best,second
        for _,enemy in ipairs(enemies or {}) do
            if enemy.alive and Scope.valid_position(enemy.point) then
                local direction=delta(enemy.point,row.from);local distance=length(direction)
                local earlier_direction=delta(enemy.point,earlier.point)
                local progress=length(earlier_direction)-distance
                local history=enemy_history[enemy.key]
                local relative=delta(velocity,history and history.velocity or {0,0,0})
                local closing=distance>0.2 and dot(direction,relative)/distance or 0
                if distance>0.2 and distance<=config.candidate_radius_m and progress>0.15 and closing>0.25 then
                    local projection=dot(direction,velocity)/speed
                    local alignment=projection/distance
                    local miss=math.sqrt(math.max(0,distance^2-projection^2))
                    local corridor=math.max(2.5,distance*0.12)
                    if alignment>=config.minimum_alignment and projection>0 and miss<=corridor then
                        local score=0.70*alignment+0.20*(1-miss/corridor)
                            +0.05*(1-distance/config.candidate_radius_m)+0.05*(enemy.priority or 0)
                        local candidate={enemy=enemy,score=score,distance=distance}
                        if not best or score>best.score then second=best;best=candidate
                        elseif not second or score>second.score then second=candidate end
                    end
                end
            end
        end
        if not best or best.score<config.minimum_score or second and best.score-second.score<config.minimum_margin then
            return uncertain(best and 'ambiguous' or 'no_candidate')
        end
        return select(best.enemy,'estimated',best.score)
    end
    return api
end
return M
