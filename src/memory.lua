-- Own-process, read-only observer. Native gameplay functions are never called.
local L = require('g60line.layout')
local Data = require('g60line.target_data')
local ObservationScope = require('g60line.observation_scope')
local ReplicationProbe = require('g60line.replication_probe')
local EnemyReader = require('g60line.enemy_reader')
local M = {}
function M.new(config, ownership)
    local ffi = require('ffi')
    assert(ffi.os == 'Windows' and ffi.abi('64bit'), 'Windows x64 required')
    ffi.cdef[[
        typedef unsigned char G60L_u8;
        typedef unsigned short G60L_u16;
        typedef unsigned int G60L_u32;
        void *GetModuleHandleA(const char *);
        void *GetCurrentProcess(void);
        int ReadProcessMemory(void *, const void *, void *, size_t, size_t *);
        G60L_u32 GetModuleFileNameW(void *, G60L_u16 *, G60L_u32);
        void *CreateFileW(const G60L_u16 *, G60L_u32, G60L_u32, void *, G60L_u32, G60L_u32, void *);
        int ReadFile(void *, void *, G60L_u32, G60L_u32 *, void *);
        int CloseHandle(void *);
        int BCryptOpenAlgorithmProvider(void **, const G60L_u16 *, const G60L_u16 *, G60L_u32);
        int BCryptCloseAlgorithmProvider(void *, G60L_u32);
        int BCryptCreateHash(void *, void **, void *, G60L_u32, const void *, G60L_u32, G60L_u32);
        int BCryptHashData(void *, const void *, G60L_u32, G60L_u32);
        int BCryptFinishHash(void *, void *, G60L_u32, G60L_u32);
        int BCryptDestroyHash(void *);
    ]]
    local kernel, bcrypt = ffi.load('kernel32'), ffi.load('bcrypt')
    local process = kernel.GetCurrentProcess()
    local game_module, exe_module = kernel.GetModuleHandleA('game.dll'), kernel.GetModuleHandleA(nil)
    assert(game_module ~= nil and exe_module ~= nil, 'game modules unavailable')
    local base, exe = tonumber(ffi.cast('uintptr_t', game_module)), tonumber(ffi.cast('uintptr_t', exe_module))
    local buffer, received = ffi.new('G60L_u8[32768]'), ffi.new('size_t[1]')
    local bytes, calls = 0, 0
    local function read(address, size)
        assert(type(address) == 'number' and address % 1 == 0 and address >= 65536
            and address + size < 2^47 and size > 0 and size <= 32768, 'read bound')
        bytes, calls = bytes + size, calls + 1
        assert(bytes <= 1048576 and calls <= 12000, 'read budget exceeded')
        assert(kernel.ReadProcessMemory(process, ffi.cast('const void *', address), buffer, size, received) ~= 0
            and tonumber(received[0]) == size, 'memory unreadable')
        return ffi.string(buffer, size)
    end
    local function hash_file(module)
        local path = ffi.new('G60L_u16[32768]')
        local length = kernel.GetModuleFileNameW(module, path, 32768)
        assert(length > 0 and length < 32768, 'module file path unavailable')
        local file = kernel.CreateFileW(path, 0x80000000, 7, nil, 3, 0x08000000, nil)
        assert(file ~= nil and file ~= ffi.cast('void *', -1), 'module file unavailable')
        local algorithm, hash = ffi.new('void *[1]'), ffi.new('void *[1]')
        local ok, digest = pcall(function()
            local name = ffi.new('G60L_u16[7]', {83, 72, 65, 50, 53, 54, 0})
            assert(bcrypt.BCryptOpenAlgorithmProvider(algorithm, name, nil, 0) == 0, 'SHA256 provider')
            assert(bcrypt.BCryptCreateHash(algorithm[0], hash, nil, 0, nil, 0, 0) == 0, 'SHA256 hash')
            local chunk, count = ffi.new('G60L_u8[1048576]'), ffi.new('G60L_u32[1]')
            while true do
                assert(kernel.ReadFile(file, chunk, 1048576, count, nil) ~= 0, 'module file read')
                if count[0] == 0 then break end
                assert(bcrypt.BCryptHashData(hash[0], chunk, count[0], 0) == 0, 'SHA256 update')
            end
            local output, parts = ffi.new('G60L_u8[32]'), {}
            assert(bcrypt.BCryptFinishHash(hash[0], output, 32, 0) == 0, 'SHA256 finish')
            for i = 0, 31 do parts[#parts + 1] = string.format('%02X', output[i]) end
            return table.concat(parts)
        end)
        if hash[0] ~= nil then bcrypt.BCryptDestroyHash(hash[0]) end
        if algorithm[0] ~= nil then bcrypt.BCryptCloseAlgorithmProvider(algorithm[0], 0) end
        kernel.CloseHandle(file)
        assert(ok, digest)
        return digest
    end
    assert(hash_file(game_module) == config.game_sha, 'unsupported game.dll build')
    assert(hash_file(exe_module) == config.exe_sha, 'unsupported executable build')
    local function check_pins(module, pins)
        for _, pin in ipairs(pins) do
            local expected = pin[2]:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end)
            assert(read(module + pin[1], #expected) == expected,
                'native layout changed at ' .. string.format('%x', pin[1]))
        end
    end
    check_pins(base, config.game_pins)
    check_pins(exe, config.exe_pins)
    bytes, calls = 0, 0
    local api = {}
    local enemy_ids,enemy_cursor,preferred={},1,{}
    function api:set_prediction_targets(targets) preferred=targets end
    function api:estimated_endpoint(id,key)
        return EnemyReader.one(read,base,exe,id,key,config)
    end
    function api:sample(known_ids, discover, origin)
        bytes, calls = 0, 0
        local d = Data.new(read, base, exe)
        local game = d.ptr(base + 0x3326340)
        local game_state = d.u32(game + 0xac21c)
        assert(game_state <= 16, 'game state bound')
        if game_state ~= 4 then enemy_ids={};enemy_cursor=1;preferred={};return {mission = false, state = game_state, rows = {}, ids = {}} end
        local manager = d.ptr(base + 0x3326740)
        local header = d.read(manager, 0x70)
        local capacity, count, active = L.u32(header, 0x20), L.u32(header, 0x2c), L.u32(header, 0x34)
        assert(active <= count and count <= capacity and capacity <= 4096, 'behavior count bound')
        local rows, ids, indices = {}, {}, {}
        local estimating=config.estimation and config.estimation.enabled
        if discover then enemy_ids={} end
        if count > 0 then
            local descriptors, records = L.pointer(header, 0x58), L.pointer(header, 0x60)
            if discover then
                local pointers = d.read(descriptors, count * 8)
                for i = 0, count - 1 do
                    local entity = L.pointer(pointers, i * 8)
                    local identity = read(entity, 24)
                    if estimating and config.estimation_enemies[L.hex64(identity,0)] then
                        enemy_ids[#enemy_ids+1]=L.u32(identity,8)
                    end
                    if L.hex64(identity, 0) == '8e325c933e55bf62' then indices[#indices + 1] = i end
                    assert(#indices <= 64, 'G60 diagnostic limit exceeded')
                end
            else
                for _, id in ipairs(known_ids) do
                    local i = d.hash(manager + 0x40, id, count)
                    if i then indices[#indices + 1] = i end
                end
            end
            for _, i in ipairs(indices) do
                local entity_address = d.ptr(descriptors + i * 8)
                local identity = d.read(entity_address, 24)
                if L.hex64(identity, 0) == '8e325c933e55bf62' then
                    local id, flags = L.u32(identity, 8), L.u32(identity, 20)
                    local record = d.read(records + i * 0x1f8, 0x1f8)
                    local row = {id = id, network = L.u32(identity, 16), state = L.u32(record, 8),
                        behavior = L.u32(record, 0), target_id = L.u32(record, 0x18),
                        flag = record:byte(0x79), eligible = i < active and math.floor(flags / 2) % 2 == 0,
                        entity_key = identity:sub(1, 20),
                        key = identity:sub(1, 20) .. record:sub(0x189, 0x190)}
                    ids[#ids + 1], rows[#rows + 1] = id, row
                    local source = d.entity(id)
                    assert(source and source.identity == identity, 'G60 identity changed')
                    local life = d.explosive_lifecycle(source)
                    row.explosive_ready, row.terminal = life.ready, life.terminal
                    row.explosive_reason, row.explosive_flags = life.reason, life.flags
                    row.reason = life.reason
                    if estimating then
                        local owner_ok,owner=pcall(ownership,row.network)
                        if owner_ok and type(owner)=='boolean' then row.locally_owned=owner end
                    end
                    if config.multiplayer_diagnostics and discover or estimating and row.locally_owned==false then
                        local probe_ok,probe=pcall(ReplicationProbe.capture,read,base,exe,i,identity,config)
                        row.replication_probe=probe_ok and probe or {error=tostring(probe)}
                        if probe_ok and estimating and row.locally_owned==false then
                            row.remote_phase=probe.state
                            row.remote_active=ReplicationProbe.remote_active(probe,row.locally_owned,life.ready,life.terminal)
                            if row.remote_active then row.from=probe.from end
                        end
                    end
                    local nearby=config.observation_mode=='nearby_active'
                    if life.ready and not life.terminal and (not nearby or ObservationScope.active(row)) then
                    row.from = row.from or d.unit_position(source, config.pose_getters, false)
                    row.reason = 'no_selection'
                    local inside=true
                    if nearby then inside,row.view_distance=ObservationScope.contains(origin,row.from,config.tracking_radius_m) end
                    row.in_range=inside
                    if not inside then row.reason='out_of_range'
                    elseif row.behavior == 4 and row.state == 4 and row.eligible and row.flag == 1
                        and row.target_id ~= d.invalid and L.u32(record, 0x68) == id then
                        local target = d.entity(row.target_id)
                        if target then
                            row.target_key = target.identity:sub(1, 20)
                            row.target_type = target.resource
                            row.native_point = Data.vector(record, 0x1c)
                            row.to, row.endpoint_kind = d.unit_position(target, config.pose_getters, true)
                            local ax, ay, az = row.to[1] - row.native_point[1], row.to[2] - row.native_point[2], row.to[3] - row.native_point[3]
                            row.point_gap = math.sqrt(ax * ax + ay * ay + az * az)
                            local dx, dy, dz = row.to[1] - row.from[1], row.to[2] - row.from[2], row.to[3] - row.from[3]
                            row.distance = math.sqrt(dx * dx + dy * dy + dz * dz)
                            -- Visibility is handled by the actual scene viewport.
                            -- Do not truncate a valid lock by an arbitrary display range.
                            if row.distance > 0.00001 then row.reason = 'selected'
                            else row.to = nil; row.reason = 'coincident_endpoints' end
                        else row.reason = 'target_missing' end
                    elseif row.flag == 1 and row.target_id == d.invalid then row.reason = 'point_guidance_unsupported'
                    elseif not row.eligible then row.reason = 'inactive'
                    elseif row.state ~= 4 then row.reason = 'state_not_4' end
                    end
                end
            end
        end
        assert(d.validate(), 'observation changed')
        local enemies,enemy_stats
        if estimating and discover then
            local sources={}
            for _,row in ipairs(rows) do
                if row.remote_active and ObservationScope.contains(origin,row.from,config.tracking_radius_m) then
                    sources[#sources+1]=row.from
                end
            end
            if #sources>0 then
                local enemy_ok,result,next_cursor,stats=pcall(EnemyReader.capture,read,base,exe,enemy_ids,sources,config,enemy_cursor,preferred)
                enemies=enemy_ok and result or {}
                if enemy_ok then enemy_cursor=next_cursor;enemy_stats=stats
                else enemy_stats={error=tostring(result)} end
            else enemies={} end
        end
        return {mission = true, state = game_state, rows = rows, ids = ids, bytes = bytes, calls = calls,
            enemies=enemies,enemy_stats=enemy_stats}
    end
    return api
end
return M
