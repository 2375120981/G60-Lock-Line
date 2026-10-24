-- Own scene objects only; mesh failure must not disable the separate point light.
local SceneLight=require('g60line.scene_light')
local BloomMarker=require('g60line.bloom_marker')
local M={}
function M.new(engine,emit,spec)
    local light=SceneLight.new(engine,emit,spec)
    local marker=BloomMarker.new(engine,emit,spec)
    local api={enabled=light.enabled,count=0,marker_count=0,available=light.available,bloom_available=marker.available}
    function api:clear()
        light:clear();marker:clear();self.count=0;self.marker_count=0
    end
    function api:sync(rows,camera,viewport)
        local ok,why=pcall(light.sync,light,rows)
        if not ok then light:clear();emit('glow_update_error '..tostring(why)) end
        local mesh_ok,mesh_why=pcall(marker.sync,marker,rows,camera,viewport)
        if not mesh_ok then marker:clear();emit('bloom_update_error '..tostring(mesh_why)) end
        self.count=light.count;self.marker_count=marker.count
        return ok and mesh_ok
    end
    return api
end
return M
