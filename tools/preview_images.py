"""Deterministic option PNGs from the shipped marker geometry and preset colors.

Transparent element illustrations only, not gameplay screenshots. Runs our pure marker Lua module,
never the observer, engine callbacks or game. Requires Pillow.
"""
import ctypes
from io import BytesIO
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
from lua_runtime import lua_library

ROOT = Path(__file__).resolve().parents[1]
W, H, AA = 960, 540, 2


def table(v):
    if isinstance(v, dict):
        return '{'+','.join('['+json.dumps(k)+']='+table(x) for k,x in v.items())+'}'
    if isinstance(v, list):
        return '{'+','.join(map(table,v))+'}'
    return json.dumps(v)


class Markers:
    """Use the same module as the addon, rather than maintaining duplicate shapes."""
    def __init__(self):
        self.dll = ctypes.CDLL(lua_library())
        d = self.dll
        d.luaL_newstate.restype = ctypes.c_void_p
        d.luaL_openlibs.argtypes = [ctypes.c_void_p]
        d.luaL_loadbuffer.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
        d.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
        d.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
        d.lua_tolstring.restype = ctypes.c_void_p
        d.lua_settop.argtypes = [ctypes.c_void_p, ctypes.c_int]
        d.lua_close.argtypes = [ctypes.c_void_p]
        self.state = d.luaL_newstate()
        assert self.state
        d.luaL_openlibs(self.state)
        self.source = (ROOT/'src/marker_shapes.lua').read_text(encoding='utf-8')

    def geometry(self, spec):
        code = ('local M=(function()\n'+self.source+'\nend)()\nlocal spec='+table(spec)+r'''
local strokes=M.is_screen(spec) and M.screen(spec,{0,0}) or M.world(spec,{0,0,0})
local rows={}
for _,stroke in ipairs(strokes) do
 local values={}
 for _,point in ipairs({stroke.from,stroke.to}) do
  for _,v in ipairs(point) do values[#values+1]=string.format('%.9f',v) end
 end
 rows[#rows+1]='['..table.concat(values,',')..']'
end
return '['..table.concat(rows,',')..']'
''').encode()
        d,s = self.dll,self.state
        d.lua_settop(s,0)
        status = d.luaL_loadbuffer(s,code,len(code),b'preview-marker-geometry')
        if not status: status = d.lua_pcall(s,0,1,0)
        size = ctypes.c_size_t()
        pointer = d.lua_tolstring(s,-1,ctypes.byref(size))
        result = ctypes.string_at(pointer,size.value).decode() if pointer else ''
        assert status == 0, result
        return json.loads(result)

    def close(self):
        self.dll.lua_close(self.state)


class Canvas:
    def __init__(self):
        self.im = Image.new('RGBA',(W*AA,H*AA),(0,0,0,0))
        self.draw = ImageDraw.Draw(self.im)

    def line(self, a, b, color, width=2):
        self.draw.line((a[0]*AA,a[1]*AA,b[0]*AA,b[1]*AA),fill=color,width=max(1,round(width*AA)))

    def shape(self, geometry, center, color, width, scale=3):
        def project(v):
            # Oblique illustrative projection for the original 3D world cross.
            if len(v)==3:
                x,y,z=v
                return (center[0]+(x-y*.6)*90*scale,center[1]-(z+y*.4)*90*scale)
            return (center[0]+v[0]*scale,center[1]-v[1]*scale)
        for stroke in geometry:
            n=len(stroke)//2
            self.line(project(stroke[:n]),project(stroke[n:]),color,width*scale)

    def indicator(self, geometry, ring, color, center=(706,294), origin=(215,355), width=1.5, scale=3):
        self.line(origin,center,color,2*scale)
        self.shape(ring,origin,color,1.5,scale)
        self.shape(geometry,center,color,width,scale)

    def body(self, center):
        x,y=center
        # Original schematic body silhouette; no game model or texture is copied.
        self.line((x-72,y+31),(x+72,y-31),(92,115,137),9)
        self.line((x-65,y-38),(x+65,y+38),(92,115,137),9)
        self.draw.rounded_rectangle(((x-17)*AA,(y-43)*AA,(x+17)*AA,(y+43)*AA),
                                    radius=12*AA,fill=(61,81,99),outline=(132,155,178),width=2*AA)

    def glow(self, center, color, radius):
        layer = Image.new('RGBA',self.im.size,(0,0,0,0))
        d = ImageDraw.Draw(layer)
        x,y=center
        d.ellipse(((x-radius)*AA,(y-radius)*AA,(x+radius)*AA,(y+radius)*AA),fill=color+(255,))
        # Illustrative halo only: game exposure/Bloom remains player-observed.
        halo = layer.filter(ImageFilter.GaussianBlur(radius*AA*.8))
        self.im.alpha_composite(halo)
        self.im.alpha_composite(layer)
        self.draw = ImageDraw.Draw(self.im)

    def png(self):
        stream=BytesIO()
        self.im.resize((W,H),Image.Resampling.LANCZOS).save(stream,format='PNG',optimize=True)
        return stream.getvalue()


def generate():
    def preset(category,choice):
        return json.loads((ROOT/'config'/category/(choice+'.json')).read_text(encoding='utf-8'))
    files={}
    markers=Markers()
    try:
        ring=markers.geometry({'style':'ring','radius_px':6,'segments':24})
        targets={choice:(title,preset('target',choice)) for choice,title in
                 [('cross','十字'),('cross_frame','十字锁定框'),('spear_triangle','飞矛三角标记')]}
        shapes={choice:markers.geometry(spec) for choice,(_,spec) in targets.items()}
        for choice,(title,spec) in targets.items():
            canvas=Canvas()
            canvas.shape(shapes[choice],(W/2,H/2),(255,255,255),spec['width_px'],scale=4)
            folder=choice.replace('_',' ').title().replace(' ','')
            files['Previews/Target/'+folder+'.png']=canvas.png()
        for choice,title in [('white','白色'),('blue','蓝色'),('yellow','黄色'),('red','红色')]:
            argb=preset('color',choice)['color_argb']
            color=tuple(argb[1:])
            canvas=Canvas()
            origin,end=(190,H/2),(790,H/2)
            canvas.line(origin,end,color,8)
            canvas.shape(ring,origin,color,1.5,scale=4)
            files['Previews/Color/'+choice.title()+'.png']=canvas.png()
        glow=preset('glow','white_red')
        canvas=Canvas()
        for locked,x in [(False,275),(True,685)]:
            center=(x,315)
            canvas.body(center)
            point=(x,315-glow['offset_z_m']*300)
            argb=glow['locked_argb'] if locked else glow['unlocked_argb']
            canvas.glow(point,tuple(argb[1:]),glow['point_radius_px']*3)
        files['Previews/Glow/WhiteRed.png']=canvas.png()
    finally:
        markers.close()
    return files


if __name__=='__main__':
    for name,body in generate().items():
        path=ROOT/'build'/name
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(body)
    print('Generated 8 option previews; no game launched.')
