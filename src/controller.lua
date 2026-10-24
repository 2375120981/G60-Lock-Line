local MarkerShapes = require('g60line.marker_shapes')
local ObservationScope = require('g60line.observation_scope')
local TargetEstimator = require('g60line.target_estimator')
local M = {}
local function coordinates(p)
    if not p then return '-' end
    return string.format('%.2f,%.2f,%.2f', p[1], p[2], p[3])
end
function M.new(reader, renderer, owned, emit, config, glow, view_origin, diagnostic_owner)
    local visual = config.visual_style or {}
    local ids, locks, reports, reference = {}, {}, {}, nil
    local lifetimes = {}
    local probe_reports = {}
    local estimator=config.estimation and config.estimation.enabled and TargetEstimator.new(config.estimation) or nil
    local enemies,enemy_sampled_at,enemy_stats={}
    local time, next_discover, next_sample = 0, 0, 0
    local last_issue, last_renderer, last_scope_issue, in_mission
    local nearby = config.observation_mode == 'nearby_active'
    local api = {stopped = false, line_count = 0, observed = 0, frames = 0, peak_ms = 0}
    local function clear()
        renderer:clear()
        if glow then glow:clear() end
        api.line_count = 0
    end
    local function reset(keep_lifetimes)
        clear(); api.observed = 0; ids, locks, reports, reference = {}, {}, {}, nil
        if estimator then estimator:reset() end
        enemies,enemy_sampled_at,enemy_stats={},nil,nil
        if not keep_lifetimes then lifetimes = {}; probe_reports = {} end
        next_discover = 0
    end
    function api:tick(dt)
        if self.stopped then return end
        local started = os.clock()
        time = time + ((type(dt) == 'number' and dt > 0 and dt < 1) and dt or 1 / 60)
        -- No grenades: scan at 5 Hz. Active grenades: refresh selected points every frame.
        local discover = time >= next_discover
        if not discover and #ids == 0 and not (reference and time < reference.expires) then return end
        if discover then next_discover = time + 0.2 end
        local origin
        if nearby then
            local origin_ok,value,reason=pcall(view_origin)
            if not origin_ok or not ObservationScope.valid_position(value) then
                reset(true);next_discover=time+0.2
                local issue=origin_ok and (reason or 'camera_position_invalid') or tostring(value)
                if issue~=last_scope_issue then emit('scope_unavailable '..issue);last_scope_issue=issue end
                return
            end
            origin=value;last_scope_issue=nil
        end
        local ok, observation = pcall(reader.sample, reader, ids, discover, origin)
        if not ok then
            reset(true)
            -- Retry at the normal discovery cadence, never hold an old target line.
            next_discover = time + 0.2
            local issue = tostring(observation)
            if issue ~= last_issue then emit('observer_error ' .. issue); last_issue = issue end
            return
        end
        last_issue = nil
        if not observation.mission then
            if in_mission then emit('mission_left state=' .. tostring(observation.state)) end
            in_mission = false; reset(); next_discover = time + 0.2
            return
        end
        if not in_mission then emit('mission_entered'); in_mission = true end
        ids = observation.ids
        if observation.enemies~=nil then enemies=observation.enemies;enemy_sampled_at=time;enemy_stats=observation.enemy_stats end
        self.observed = #observation.rows
        local segments, lights, seen, current_reports,preferred = {}, {}, {}, {},{}
        for _, row in ipairs(observation.rows) do
            seen[row.key] = true
            local status = row.reason
            local locked = false
            -- Keep a terminal latch by entity generation, independent of the
            -- flight timer and brief holes in behavior rows or failed samples.
            local entity_key = row.entity_key or row.key
            local life = lifetimes[row.id]
            if not life or life.key ~= entity_key then
                life = {key = entity_key}; lifetimes[row.id] = life
            end
            if row.terminal or (life.verified and row.explosive_reason == 'explosive_component_missing') then
                life.ended = true
            end
            if row.explosive_ready then life.verified = true end
            if config.multiplayer_diagnostics and row.replication_probe then
                local probe=row.replication_probe
                local signature=probe.error or table.concat({row.state,row.eligible and 1 or 0,
                    probe.state,probe.behavior,probe.source_id,probe.flags,probe.event},':')
                local previous=probe_reports[entity_key]
                if not previous or previous.signature~=signature or time-previous.time>=2 then
                    probe_reports[entity_key]={signature=signature,time=time}
                    local owner_ok,owner=pcall(diagnostic_owner,row.network)
                    owner=owner_ok and tostring(owner) or 'unavailable'
                    if probe.error then emit('replica_probe id='..row.id..' network='..row.network
                        ..' locally_owned='..owner..' error='..probe.error)
                    else
                        local inside,distance=ObservationScope.contains(origin,probe.from,config.tracking_radius_m)
                        emit('replica_probe id='..row.id..' network='..row.network..' locally_owned='..owner
                            ..' native_state='..row.state..' eligible='..tostring(row.eligible)
                            ..' entity_flags='..probe.entity_flags..' index='..probe.index
                            ..' active='..probe.active..' total='..probe.total
                            ..' replica_state='..probe.state..' replica_behavior='..probe.behavior
                            ..' source_id='..probe.source_id..' flags='..probe.flags..' event='..probe.event
                            ..' from='..coordinates(probe.from)..' in_range='..tostring(inside)
                            ..' view_distance='..(distance and string.format('%.2f',distance) or '-')
                            ..' raw='..probe.raw)
                        if probe.position_error then emit('replica_pose id='..row.id..' error='..probe.position_error) end
                    end
                end
            end
            local display_allowed
            if nearby then
                local inside,distance=ObservationScope.contains(origin,row.from,config.tracking_radius_m)
                row.view_distance=distance
                display_allowed=ObservationScope.active(row) and inside
                if not ObservationScope.active(row) then status='inactive_or_state_unavailable'
                elseif not inside then status='out_of_range' end
            else
                local owner_ok,owner_result=pcall(owned,row.network)
                display_allowed=owner_ok and owner_result==true
                if not display_allowed then status='not_locally_owned_or_unavailable' end
            end
            if life.ended then status = 'g60_ended'; locks[row.key] = nil
                if estimator then estimator:forget(entity_key) end
            end
            if estimator then
                if not life.ended and display_allowed and row.remote_active and not row.to then
                    local candidate,reason,score,pending=estimator:choose(row,enemies,time,enemy_sampled_at)
                    if candidate then preferred[#preferred+1]=candidate.id end
                    if pending then preferred[#preferred+1]=pending.id end
                    row.estimate_reason=reason
                    if candidate then
                        local endpoint_ok,endpoint=pcall(reader.estimated_endpoint,reader,candidate.id,candidate.key)
                        if endpoint_ok and endpoint and endpoint.alive then
                            row.to,row.target_id,row.target_key=endpoint.point,endpoint.id,endpoint.key
                            row.target_type,row.endpoint_kind=endpoint.resource,endpoint.endpoint_kind
                            row.estimated,row.estimate_score=true,score
                            status='estimated_selection'
                        else estimator:forget(entity_key);row.estimate_reason='candidate_invalid' end
                    end
                else estimator:forget(entity_key) end
            end
            if life.ended then
                -- Terminal entities never enter either the real or inferred lock path.
            elseif display_allowed and row.to then
                local previous = locks[row.key]
                -- An old target ID reused for a different entity must not reuse its line.
                if previous and previous.id == row.target_id and previous.key ~= row.target_key then
                    previous.blocked = true
                end
                if previous and previous.id == row.target_id and previous.blocked then status = 'target_id_reused'
                else
                    locks[row.key] = {id = row.target_id, key = row.target_key}
                    locked = true
                    segments[#segments + 1] = {from = row.from, to = row.to, start_marker = visual.g60_marker}
                    if config.endpoint_marker then
                        if row.estimated then segments[#segments].estimated_marker=MarkerShapes.estimated_ring(visual.target_marker) end
                        if MarkerShapes.is_screen(visual.target_marker) then
                            segments[#segments].end_marker = visual.target_marker
                        end
                        for _, marker in ipairs(MarkerShapes.world(visual.target_marker, row.to)) do
                            segments[#segments + 1] = marker
                        end
                    end
                end
            else locks[row.key] = nil end
            if display_allowed and row.remote_active and not life.ended and not locked then
                segments[#segments+1]={from=row.from,to=row.from,start_marker=visual.g60_marker}
            end
            if config.glow and config.glow.enabled and not life.ended and display_allowed
                and row.explosive_ready and row.from and ObservationScope.active(row) then
                lights[#lights+1]={id=row.id,key=entity_key,locked=locked,
                    from={row.from[1],row.from[2],row.from[3]+config.glow.offset_z_m}}
            end
            if config.reference and not reference and display_allowed and row.from then
                local p = row.from
                reference = {expires = time + 12, from = {p[1] - 2, p[2], p[3] + 1},
                    to = {p[1] + 2, p[2], p[3] + 1}, reference = true}
                emit('reference_started duration=12 from=' .. coordinates(reference.from) .. ' to=' .. coordinates(reference.to))
            end
            local signature = table.concat({row.state, row.flag, row.target_id, status, row.target_type or '-',
                row.explosive_reason or '-', row.explosive_flags or '-',row.estimate_reason or '-',row.estimated and 'estimated' or 'native'}, ':')
            current_reports[row.key] = signature
            if signature ~= reports[row.key] then
                emit('G60 id=' .. row.id .. ' state=' .. row.state .. ' flag=' .. row.flag .. ' target=' .. row.target_id
                    .. ' status=' .. status .. ' type=' .. (row.target_type or '-')
                    .. ' anchor=' .. (row.endpoint_kind or '-')
                    .. ' explosive=' .. (row.explosive_reason or '-') .. ' flags=' .. (row.explosive_flags or '-')
                    .. ' selection='..(row.estimated and 'estimated' or 'native')..' estimate='..(row.estimate_reason or '-'))
            end
        end
        for key in pairs(locks) do if not seen[key] then locks[key] = nil end end
        local live_entities={}
        for _,row in ipairs(observation.rows) do live_entities[row.entity_key or row.key]=true end
        for key in pairs(probe_reports) do if not live_entities[key] then probe_reports[key]=nil end end
        if estimator then estimator:prune(live_entities) end
        if estimator and type(reader.set_prediction_targets)=='function' then reader:set_prediction_targets(preferred) end
        for key in pairs(reports) do if not seen[key] then emit('G60_removed') end end
        reports = current_reports
        if reference and time < reference.expires then segments[#segments + 1] = reference end
        local draw_ok, visible, render_reason = pcall(renderer.draw, renderer, segments)
        local render_status = draw_ok and (visible and (render_reason or 'submitted') or tostring(render_reason)) or tostring(visible)
        if not draw_ok or not visible then clear()
        elseif glow then
            -- The camera is resolved by draw and consumed within this frame only.
            local glow_ok,glow_error=pcall(glow.sync,glow,lights,renderer.camera_model,renderer.viewport)
            renderer.camera_model,renderer.viewport=nil,nil
            if not glow_ok then pcall(glow.clear,glow);emit('glow_update_error '..tostring(glow_error)) end
        end
        if render_status ~= last_renderer then emit('renderer=' .. render_status); last_renderer = render_status end
        self.line_count = draw_ok and visible and (renderer.count or #segments) or 0
        self.frames = self.frames + 1
        self.peak_ms = math.max(self.peak_ms, (os.clock() - started) * 1000)
        if time >= next_sample and #observation.rows > 0 then
            next_sample = time + 2
            for _, row in ipairs(observation.rows) do
                emit('sample id=' .. row.id .. ' from=' .. coordinates(row.from) .. ' point=' .. coordinates(row.to)
                    .. ' native=' .. coordinates(row.native_point) .. ' length=' .. string.format('%.2f', row.distance or 0)
                    .. ' cache_gap=' .. string.format('%.2f', row.point_gap or 0)
                    .. ' anchor=' .. (row.endpoint_kind or '-')
                    .. ' view_distance=' .. (row.view_distance and string.format('%.2f',row.view_distance) or '-'))
            end
            emit('summary observed=' .. self.observed .. ' segments=' .. self.line_count
                .. ' reads=' .. (observation.calls or 0) .. ' bytes=' .. (observation.bytes or 0)
                .. ' peak_cpu_ms=' .. string.format('%.3f', self.peak_ms))
            if estimator then emit('estimate_pool candidates='..#enemies..' checked='..(enemy_stats and enemy_stats.checked or 0)
                ..' errors='..(enemy_stats and enemy_stats.errors or 0)
                ..' detail='..(enemy_stats and (enemy_stats.error or enemy_stats.last_error) or '-')) end
        end
    end
    function api:stop()
        if self.stopped then return end
        self.stopped = true; reset(); emit('stopped')
    end
    return api
end
return M
