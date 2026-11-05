-- Preset parameters copied from the user project V1.2.2 config/color and config/target.
local M={}
local colors={{255,255,255,255},{255,255,0,0},{255,0,128,255},{255,255,255,0}}
local shapes={{style="cross_frame",half_size_px=20,gap_px=6,width_px=1.5},{style="world_cross",half_size_m=0.2,width_px=1.5},{style="spear_triangle",half_size_px=10,corner_radius_px=1.5,width_px=1.5}}
M.options={
 {key='line_color',type='number',label='线条颜色：1白色 / 2红色 / 3蓝色 / 4黄色',min=1,max=4,step=1,default=1},
 {key='target_shape',type='number',label='锁定标记：1方框十字 / 2十字 / 3飞矛准星',min=1,max=3,step=1,default=1}
}
local function index(v,max)
 if type(v)=='number'and v==math.floor(v)and v>=1 and v<=max then return v end
 return 1
end
function M.resolve(settings)
 settings=type(settings)=='table'and settings or{}
 local color,shape=index(settings.line_color,#colors),index(settings.target_shape,#shapes)
 local argb={};for i,v in ipairs(colors[color])do argb[i]=v end
 local marker={};for k,v in pairs(shapes[shape])do marker[k]=v end
 return {color_argb=argb,line_width_px=2,
  g60_marker={style='ring',radius_px=6,width_px=1.5,segments=24},target_marker=marker},color..'/'..shape
end
return M
