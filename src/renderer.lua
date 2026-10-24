-- Candidate Stingray world-line API. Its visibility must be verified in game.
local WorldGuiRenderer = require('g60line.world_gui_renderer')
local ScreenRenderer = require('g60line.screen_renderer')
local M = {}
local function has(object, name) return type(object) == 'table' and type(object[name]) == 'function' end
function M.new(engine, emit, config)
    config = config or {}
    if config.renderer == 'screen_gui' then return ScreenRenderer.new(engine, emit, config) end
    if config.renderer == 'world_gui' then return WorldGuiRenderer.new(engine, emit, config) end
    local App, World, Lines = engine.Application, engine.World, engine.LineObject
    local missing = {}
    for _, item in ipairs({{App, 'worlds'}, {App, 'main_world'}, {World, 'create_line_object'},
        {World, 'destroy_line_object'}, {Lines, 'reset'}, {Lines, 'add_line'}, {Lines, 'dispatch'}}) do
        if not has(item[1], item[2]) then missing[#missing + 1] = item[2] end
    end
    -- Engine constructors can be callable tables/userdata, not Lua functions.
    -- Check the documented constructor call instead of its Lua type.
    local vector_ok, vector_result = pcall(function() return engine.Vector3(0, 0, 0) end)
    local color_ok, color_result = pcall(function() return engine.Color(255, 255, 205, 55) end)
    emit('constructors Vector3_type=' .. type(engine.Vector3) .. ' Vector3_ok=' .. tostring(vector_ok)
        .. ' Color_type=' .. type(engine.Color) .. ' Color_ok=' .. tostring(color_ok))
    if not vector_ok or vector_result == nil then
        missing[#missing + 1] = 'Vector3'
        emit('Vector3_probe_failed ' .. tostring(vector_result))
    end
    if not color_ok or color_result == nil then
        missing[#missing + 1] = 'Color'
        emit('Color_probe_failed ' .. tostring(color_result))
    end
    local api = {available = #missing == 0, missing = table.concat(missing, ','), count = 0}
    local world, object
    local function world_exists(worlds, wanted)
        if type(worlds) ~= 'table' or wanted == nil then return false end
        for _, value in pairs(worlds) do if value == wanted then return true end end
        return false
    end
    local function release(worlds)
        local old_world, old_object = world, object
        world, object, api.count = nil, nil, 0
        if old_object ~= nil and world_exists(worlds, old_world) then
            pcall(Lines.reset, old_object)
            pcall(World.destroy_line_object, old_world, old_object)
        end
    end
    function api:draw(segments)
        if not self.available then return false, self.missing end
        local worlds, current = App.worlds(), App.main_world()
        if not world_exists(worlds, current) then release(worlds); return false, 'main_world_unavailable' end
        if world ~= current then release(worlds) end
        if #segments == 0 and object == nil then return true end
        if object == nil then
            object = assert(World.create_line_object(current, config.disable_depth_test == true), 'line object creation failed')
            world = current
            emit('renderer_created depth_test=' .. tostring(config.disable_depth_test ~= true))
        end
        Lines.reset(object)
        for _, segment in ipairs(segments) do
            local a, b = segment.from, segment.to
            local color = segment.reference and engine.Color(255, 80, 220, 255)
                or segment.marker and engine.Color(255, 255, 255, 255) or engine.Color(255, 255, 205, 55)
            Lines.add_line(object, color, engine.Vector3(a[1], a[2], a[3]), engine.Vector3(b[1], b[2], b[3]))
        end
        Lines.dispatch(world, object)
        self.count = #segments
        return true
    end
    function api:clear()
        if object == nil then return end
        -- Do not call an engine destructor on a World that has already disappeared.
        local ok, worlds = pcall(App.worlds)
        if ok then release(worlds) else world, object, self.count = nil, nil, 0 end
    end
    return api
end
return M
