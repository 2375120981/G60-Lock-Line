"""Build a manager-installable MDL addon; writes only into this project."""
from pathlib import Path
import argparse,json,re,struct,hashlib,uuid,zipfile,sys
ROOT=Path(__file__).resolve().parents[1]
BASE='mods/2375120981/g60_lock_line/'
ENTRY=BASE+'main'
PATCH='9ba626afa44a3aa3.patch_0'
LUA=0xA14E8DFA2CD117E2
VERSION='1.0.2'

def resource_hash(name):
 data=name.encode();mask=(1<<64)-1;m=0xC6A4A7935BD1E995;h=len(data)*m&mask
 end=len(data)//8*8
 for at in range(0,end,8):
  k=int.from_bytes(data[at:at+8],'little')*m&mask;k^=k>>47;k=k*m&mask
  h=(h^k)*m&mask
 if end<len(data):h=(h^int.from_bytes(data[end:],'little'))*m&mask
 h^=h>>47;h=h*m&mask
 return h^(h>>47)

def archive(sources):
 count=len(sources);start=(104+count*80+15)//16*16
 body,entries=bytearray(),bytearray()
 for i,(name,source)in enumerate(sorted(sources.items())):
  payload=struct.pack('<II',len(source),2)+source
  entries.extend(struct.pack('<7Q6I',resource_hash(name),LUA,start+len(body),0,0,0,0,len(payload),0,0,16,16,i))
  body.extend(payload);body.extend(b'\0'*(-len(body)%16))
 header=struct.pack('<III20sQQ24s',0xF0000011,1,count,b'',start+len(body),0,b'')
 data=header+struct.pack('<IIQIIII',0,0,LUA,count,0,16,16)+entries
 return bytes(data+b'\0'*(start-len(data))+body)

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--deps',type=Path);args=parser.parse_args()
 if args.deps:sys.path.insert(0,str(args.deps.resolve()))
 from lupa.lua51 import LuaRuntime
 raw={};pending=['mod']
 while pending:
  name=pending.pop()
  if name in raw:continue
  source=(ROOT/'g60_read_probe'/f'{name}.lua').read_text(encoding='utf8')
  raw[name]=source
  pending.extend(re.findall(r"require\(['\"]([^'\"]+)['\"]\)",source))
 assert 'probe_hud'not in raw and 'probe_glyphs'not in raw and 'probe_enemies'not in raw
 sources={}
 for name,source in raw.items():
  resource=ENTRY if name=='mod'else BASE+name
  source=re.sub(r"require\(['\"]([^'\"]+)['\"]\)",lambda m:"require('"+BASE+m[1]+"')",source)
  source=source.replace('(MDL validation port)','(MDL port)')
  if name=='mod':source='-- HD2-Addon: '+ENTRY+'\n'+source
  sources[resource]=source.encode('utf8')
 lua=LuaRuntime(unpack_returned_tuples=True)
 for name,source in sources.items():
  lua.compile(source.decode(),name=name)
  for dep in re.findall(r"require\(['\"]([^'\"]+)['\"]\)",source.decode()):assert dep in sources,(name,dep)
 assert sum(b'-- HD2-Addon:'in s for s in sources.values())==1
 source=sources[ENTRY].decode()
 for text in ['MDL验证','读取测试','io.open','SNAPSHOT','SUMMARY']:assert text not in source,text
 patch=archive(sources);assert len(patch)==struct.unpack_from('<Q',patch,32)[0]
 decoded={}
 for i in range(len(sources)):
  e=struct.unpack_from('<7Q6I',patch,104+i*80);size,fmt=struct.unpack_from('<II',patch,e[2])
  assert e[1]==LUA and fmt==2 and size==e[7]-8
  decoded[e[0]]=patch[e[2]+8:e[2]+8+size]
 for name,body in sources.items():assert decoded[resource_hash(name)]==body
 # Load the actual namespaced resources through a mock MDL host. No game calls.
 lua.globals().SOURCES=lua.table_from({n:s.decode()for n,s in sources.items()})
 lua.globals().BASE=BASE;lua.globals().ENTRY=ENTRY;lua.globals().VERSION=VERSION
 checks=lua.execute((ROOT/'tests/release_package.lua').read_text(encoding='utf8'))
 readme="""# G60 锁定线 1.0.2

将压缩包导入管理器，启用并部署，重启游戏后在 MDL 中启用“G60 锁定线”。升级时请移除先前手动安装的版本，避免重复加载。

支持本机与队友 G60 连线、目标标记及队友目标估算。估算目标附加圆环。
无 G60 时暂停场景扫描和模型坐标查询，保留轻量敌人事件记录；首次投掷后按需预热，期间保留网络位置显示。\n在 MDL 设置中点击切换：白 / 红 / 蓝 / 黄；方框十字 / 十字 / 飞矛准星。默认白色＋方框十字。

依赖 MDL3；建议同时启用 HD2 Data Hub，以提供更多敌人候选。
MDL3 与 HD2 Data Hub 作者：M!ni$try0fSc!eиce。
请前往 [MDL3 官方发布页](https://ayakamods.com/mods/mdl3-preview-%E9%BA%A6%E5%BD%93%E5%8A%B33-%E9%A2%84%E8%A7%88%E7%89%88%EF%BC%81.5710/) 阅读说明与免责条款并下载安装。包内不包含这些依赖组件。
"""
 credits="""# 来源

原项目：[2375120981/G60-Lock-Line](https://github.com/2375120981/G60-Lock-Line)，V1.2.2，提交 cd433d5c67bfd0d25b8b0e82a97baf1d24a5a0ce。
相机投影、几何标记、目标估算和外观参数沿用该项目；MDL 读取与生命周期适配独立实现。
循环设置参考 BFV Hit And Kill Feedback V2.2.0 的 ModOptionsMenu 接口用法；不包含其组件。
本模组为非官方适配，不代表 MDL3 作者或游戏官方提供担保。
"""
 guid=str(uuid.uuid5(uuid.NAMESPACE_URL,'https://github.com/2375120981/G60-Lock-Line/MDL'))
 manifest={'Guid':guid,'Name':'G60 锁定线','Version':VERSION,'Description':'显示G60锁定连线与目标标记，支持队友目标估算和配色、形状设置。需要MDL3。'}
 files={'manifest.json':(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n').encode(),
  'mod-manager.xml':'<mod id="g60-lock-line-mdl" name="G60 锁定线" />\n'.encode('utf8'),
  'README.md':readme.encode(),'CREDITS.md':credits.encode(),PATCH:patch,PATCH+'.stream':b'',PATCH+'.gpu_resources':b''}
 dist=ROOT/'release';dist.mkdir(exist_ok=True)
 output=dist/f'G60-Lock-Line-MDL-v{VERSION}.zip'
 with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED)as z:
  for name,body in sorted(files.items()):
   info=zipfile.ZipInfo(name,(2026,11,5,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=0o100644<<16
   z.writestr(info,body)
 with zipfile.ZipFile(output)as z:
  assert z.testzip()is None
  for n,b in files.items():assert z.read(n)==b
  assert not any(n.endswith(('.lua','.log','.bak'))or'test'in n.lower()for n in z.namelist())
 report={'version':VERSION,'path':str(output.resolve()),'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),
  'bytes':output.stat().st_size,'resource_count':len(sources),'entry':ENTRY,'guid':guid,
  'user_verified_baseline':'1.0.0','packaged_runtime_verified':False,'checks':dict(checks.items()),
  'no_debug_hud':True,'no_font_resources':True,'no_snapshot_file_logging':True,'no_mdl_or_hub_bundled':True,
  'package_files':list(files),'source_sha256':{n:hashlib.sha256(s).hexdigest()for n,s in sources.items()}}
 (ROOT/f'VERIFICATION-{VERSION}.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
 print(json.dumps({k:report[k]for k in ['path','bytes','resource_count','sha256']},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
