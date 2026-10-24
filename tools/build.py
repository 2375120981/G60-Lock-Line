"""Build a self-contained BSL addon and option art; no game writes."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import struct
import uuid
from itertools import product
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED
from light_asset import light_unit, LIGHT_RESOURCE
from bloom_asset import asset_archive, resources, MARKER_RESOURCE, WHITE_MATERIAL, RED_MATERIAL, TEMPLATE_SHA
from preview_images import generate as generate_previews

ROOT = Path(__file__).resolve().parents[1]
RESOURCE = 'mods/c09nat/g60_lock_line'
PATCH = '9ba626afa44a3aa3.patch_0'
LUA_TYPE = 0xA14E8DFA2CD117E2
CONFIG = json.loads((ROOT / 'compat/build.json').read_text(encoding='utf-8'))
VERSION = CONFIG['version']
COVER = CONFIG.get('include_cover',CONFIG.get('release_status') == 'final')
USER_VERIFIED = CONFIG.get('user_verified', VERSION in ('0.1.16','1.0.0'))
MODULES = [('layout', 'Layout'), ('target_data', 'TargetData'), ('observation_scope', 'ObservationScope'),
           ('replication_probe','ReplicationProbe'), ('enemy_reader','EnemyReader'),
           ('target_estimator','TargetEstimator'), ('memory', 'Memory'),
           ('geometry', 'Geometry'), ('world_gui_renderer', 'WorldGuiRenderer'),
           ('projection', 'Projection'), ('camera_selector', 'CameraSelector'), ('marker_shapes', 'MarkerShapes'), ('screen_renderer', 'ScreenRenderer'),
           ('renderer', 'Renderer'), ('controller', 'Controller'), ('preset_options', 'PresetOptions'),
           ('scene_light', 'SceneLight'), ('bloom_marker', 'BloomMarker'), ('glow_renderer', 'GlowRenderer')]


def lua(value):
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return '{' + ','.join(lua(item) for item in value) + '}'
    if isinstance(value, dict):
        return '{' + ','.join('[' + lua(key) + ']=' + lua(item) for key, item in value.items()) + '}'
    raise TypeError(type(value))


def assemble(reference: bool) -> bytes:
    modules = []
    for name, alias in MODULES:
        source = (ROOT / 'src' / (name + '.lua')).read_text(encoding='utf-8')
        for dependency, replacement in MODULES:
            source = source.replace("require('g60line." + dependency + "')", replacement)
        modules.append('local ' + alias + '=(function()\n' + source + '\nend)()')
    config = {key: CONFIG[key] for key in ('game_sha', 'exe_sha', 'game_pins', 'exe_pins')}
    config['reference'] = reference
    config['observation_mode'] = CONFIG.get('observation_mode','nearby_active')
    config['tracking_radius_m'] = CONFIG.get('tracking_radius_m',80)
    config['multiplayer_diagnostics'] = CONFIG.get('multiplayer_diagnostics',False)
    config['estimation']=json.loads((ROOT/'config/estimation.json').read_text(encoding='utf-8'))
    config['estimation_enemies']=json.loads((ROOT/'config/estimation-enemies.json').read_text(encoding='utf-8'))
    config['disable_depth_test'] = reference
    config['endpoint_marker'] = True
    config['visual_style'] = json.loads((ROOT / 'config/visual-style.json').read_text(encoding='utf-8'))
    config['renderer'] = 'screen_gui'
    config['line_width'] = 0.04
    config['pose_getters'] = {int(key): value for key, value in CONFIG['pose_getters'].items()}
    entry = (ROOT / 'src/addon.lua.in').read_text(encoding='utf-8')
    entry = entry.replace('@@MODULES@@', '\n'.join(modules)).replace('@@CONFIG@@', lua(config))
    entry = entry.replace('@@VERSION@@', VERSION)
    notices=(ROOT/'THIRD-PARTY-NOTICES.md').read_text(encoding='utf-8')
    license_text=notices.split('## MIT License — etxp source',1)[1].strip()
    legal='--[[\nAdapted read-only code: https://github.com/etxp/HD2-G60-Smart-Targeting\n'+license_text+'\nGame-derived material data retains its original asset rights.\n]]\n'
    first_line,rest=entry.split('\n',1)
    entry=first_line+'\n'+legal+rest
    assert '@@' not in entry and "require('g60line." not in entry
    for forbidden in ('WriteProcessMemory', 'VirtualProtect', 'VirtualAlloc', 'calls.explode',
                      'calls.remove', 'calls.clear', 'ffi.copy', "ffi.cast('void (*)"):
        assert forbidden not in entry, 'Unexpected gameplay/memory-write capability: ' + forbidden
    return entry.encode('utf-8')


def murmur64(data: bytes) -> int:
    mask, multiplier = (1 << 64) - 1, 0xC6A4A7935BD1E995
    value = len(data) * multiplier & mask
    end = len(data) // 8 * 8
    for offset in range(0, end, 8):
        block = int.from_bytes(data[offset:offset + 8], 'little') * multiplier & mask
        block ^= block >> 47
        block = block * multiplier & mask
        value = (value ^ block) * multiplier & mask
    if end < len(data):
        value ^= int.from_bytes(data[end:], 'little')
        value = value * multiplier & mask
    value ^= value >> 47
    value = value * multiplier & mask
    return value ^ (value >> 47)


def archive(source: bytes, resource: str = RESOURCE) -> bytes:
    if resource == RESOURCE:
        assert source.startswith(('-- HD2-Addon: ' + RESOURCE + '\n').encode())
    else:
        assert source.startswith(b'-- G60 option preset\n') and b'HD2-Addon:' not in source
    assert b'\0' not in source
    payload = struct.pack('<II', len(source), 2) + source
    offset = 192
    length = (offset + len(payload) + 15) & ~15
    result = bytearray(length)
    struct.pack_into('<III20sQQ24s', result, 0, 0xF0000011, 1, 1, b'', length, 0, b'')
    struct.pack_into('<IIQIIII', result, 72, 0, 0, LUA_TYPE, 1, 0, 16, 16)
    struct.pack_into('<7Q6I', result, 104, murmur64(resource.encode()), LUA_TYPE, offset,
                     0, 0, 0, 0, len(payload), 0, 0, 16, 16, 0)
    result[offset:offset + len(payload)] = payload
    return bytes(result)


def json_bytes(value) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


def main():
    (ROOT / 'build').mkdir(exist_ok=True)
    files, hashes = {}, {}
    def add_archive(folder, patch, source, resource):
        body = archive(source, resource)
        files[folder + '/' + patch] = body
        files[folder + '/' + patch + '.stream'] = b''
        files[folder + '/' + patch + '.gpu_resources'] = b''
        hashes[folder] = {'resource': resource, 'patch': patch,
                          'source_sha256': hashlib.sha256(source).hexdigest(),
                          'archive_sha256': hashlib.sha256(body).hexdigest()}
    standard = assemble(False)
    (ROOT / 'build/standard.lua').write_bytes(standard)
    add_archive('Core', PATCH, standard, RESOURCE)
    for category, choice, index in [('target', 'cross', 1), ('target', 'cross_frame', 1), ('target', 'spear_triangle', 1),
                                    ('color', 'white', 2), ('color', 'blue', 2), ('color', 'yellow', 2), ('color', 'red', 2),
                                    ('glow', 'white_red', 3)]:
        preset = json.loads((ROOT / 'config' / category / (choice + '.json')).read_text(encoding='utf-8'))
        source = ('-- G60 option preset\nreturn ' + lua(preset) + '\n').encode('utf-8')
        folder = category.title() + '/' + choice.replace('_', ' ').title().replace(' ', '')
        patch = PATCH.removesuffix('0') + str(index)
        add_archive(folder, patch, source, RESOURCE + '_' + category)
    light_body=asset_archive(murmur64)
    light_patch=PATCH.removesuffix('0')+'4'
    files['Glow/WhiteRed/'+light_patch]=light_body
    files['Glow/WhiteRed/'+light_patch+'.stream']=b''
    files['Glow/WhiteRed/'+light_patch+'.gpu_resources']=b''
    options = [
        {'Name': '目标', 'Description': '选择目标端指示器样式。', 'Include': ['Core'],
         'SubOptions': [
             {'Name': '十字', 'Description': '十字', 'Include': ['Target/Cross']},
             {'Name': '十字锁定框', 'Description': '十字锁定框',
              'Include': ['Target/CrossFrame']},
             {'Name': '飞矛三角标记', 'Description': '飞矛三角标记',
              'Include': ['Target/SpearTriangle']} ]},
        {'Name': '颜色', 'Description': '统一设置指示线、G60圆圈和目标指示器颜色。',
         'SubOptions': [{'Name': title, 'Description': '指示线、圆圈和目标指示器均为'+title+'。',
                         'Include': ['Color/'+choice]} for title,choice in
                        [('白色','White'),('蓝色','Blue'),('黄色','Yellow'),('红色','Red')] ]},
        {'Name': '发光', 'Description': '独立自发光标记和光源跟随G60，支持游戏原生Bloom。',
         'SubOptions': [
             {'Name': '双色常亮：白色／红色（原生泛光）', 'Description': '投出后无锁定白色，有效锁定红色；场景HDR标记接入原生Bloom，G60结束时清除。',
              'Include': ['Glow/WhiteRed']} ]}
    ]
    for group in options:
        group['Description']=''
        for choice in group['SubOptions']:
            choice['Description']=''
            choice['Name']=choice['Name'].replace('（原生泛光）','')
    previews=generate_previews()
    for group in options:
        for choice in group['SubOptions']:
            folder=choice['Include'][0]
            image_path='Previews/'+folder+'.png'
            assert image_path in previews
            choice['Image']=image_path
    assert len(previews)==sum(len(group['SubOptions']) for group in options)
    files.update(previews)
    for name,body in previews.items():
        path=ROOT/'build'/name
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(body)
    if COVER:
        cover=(ROOT/CONFIG['cover_asset']).read_bytes()
        assert cover.startswith(b'\x89PNG\r\n\x1a\n')
        files['Cover.png']=cover
    manifest = {'Version': 1,
        'Guid': str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://local.c09nat/helldivers2/g60-lock-line')),
        'Name': 'G60 锁定指示线 V' + VERSION,
        'Description': '',
        'Options': options}
    if COVER: manifest['IconPath']='Cover.png'
    files['manifest.json']=json_bytes(manifest)
    report = {'version': VERSION, 'resource': RESOURCE, 'build': 'F5FEE03DCFDB',
              'gameplay_writes': False, 'ingame_tested': USER_VERIFIED,
              'release_status':CONFIG.get('release_status','test'),
              'validation_basis':CONFIG.get('validation_basis','user_accepted_v0.1.16' if USER_VERIFIED else 'pending_user_multiplayer_capture'), 'render_api_visibility_verified': False,
              'multiplayer_diagnostics':CONFIG.get('multiplayer_diagnostics',False),
              'native_lifetime_verified': False, 'components': hashes,
              'endpoint': 'live_unit_pose_body_or_root', 'renderer': 'screen_gui_camera_projection',
              'visual_style': json.loads((ROOT / 'config/visual-style.json').read_text(encoding='utf-8')),
              'camera_discovery_verified': False, 'viewport_edges_verified': False,
              'observation': {'mode':CONFIG['observation_mode'],'radius_m':CONFIG['tracking_radius_m'],
                              'center':'main_world_last_rendered_camera','local_ownership_required':False,
                              'remote_state_availability_verified':False},
              'prediction':{'config':json.loads((ROOT/'config/estimation.json').read_text(encoding='utf-8')),
                            'enemy_resources':len(json.loads((ROOT/'config/estimation-enemies.json').read_text(encoding='utf-8'))),
                            'own_targets':'native_only','remote_targets':'local_inference',
                            'uncertain_display':'continuously_rank_heading_distance_priority_with_live_target_switch_dwell',
                            'outer_ring_min_radius_px':32,'ingame_verified':False},
              'menu': {'target': ['cross', 'cross_frame', 'spear_triangle'], 'color': ['white','blue','yellow','red'], 'glow': ['white_red']},
              'option_previews': {'count':len(previews),'format':'PNG','size':[960,540],
                                  'kind':'illustration_from_current_marker_geometry_and_presets',
                                  'gameplay_screenshot':False,'transparent_background':True,'captions':False,'manifest_field':'Image',
                                  'sha256':{name:hashlib.sha256(body).hexdigest() for name,body in previews.items()}},
              'spear_triangle': {'source':'user_screenshot_recreation','original_texture_extracted':False,
                                 'width_px':20,'line_width_px':1.5,'ingame_tested':False},
              'cross_frame_ingame_tested': False,
              'explosive_lifecycle_guard': 'read_only_request_flags_and_entity_generation_latch',
              'explosive_lifecycle_ingame_tested': False,
              'glow_implemented': True,
              'glow_ingame_tested': False,
              'native_bloom_implemented': True,
              'native_bloom_ingame_tested': False,
              'bloom_asset': {'marker_resource':MARKER_RESOURCE,'materials':[WHITE_MATERIAL,RED_MATERIAL],
                              'template_sha256':TEMPLATE_SHA,'emissive_intensity':32,
                              'global_bloom_settings_modified':False},
              'glow_light_intensity': 8,
              'glow_light_radius_m': 5,
              'glow_offset_z_m': json.loads((ROOT/'config/glow/white_red.json').read_text(encoding='utf-8'))['offset_z_m'],
              'glow_point_radius_px': json.loads((ROOT/'config/glow/white_red.json').read_text(encoding='utf-8'))['point_radius_px'],
              'glow_baseline': {'version':'0.1.9','point_visible_confirmed_by_user':True,
                                'light_unit_created_confirmed_in_log':True,'surface_illumination_confirmed':False},
              'light_asset': {'resource': LIGHT_RESOURCE,'patch': light_patch,
                              'unit_sha256': hashlib.sha256(light_unit(murmur64)).hexdigest(),
                              'archive_sha256': hashlib.sha256(light_body).hexdigest(),
                              'unit_compiled_version': 10800438,'game_unit_spawn_verified': False},
              'lifecycle_baseline': {'version':'0.1.8','confirmed_by_user':True},
              'visual_baseline': {'version': '0.1.5', 'confirmed_by_user': True},
              'source_commit': CONFIG['provenance']['upstream_commit']}
    if USER_VERIFIED:
        report['acceptance_record']='research/player-tests/2026-10-10-v0.1.16-result.json'
    if COVER:
        report['cover']={'path':'Cover.png','sha256':hashlib.sha256(cover).hexdigest(),'kind':'generated_promotional_illustration'}
    # Ship only declared runtime archives and referenced artwork. Reports stay local.
    allowed={'manifest.json'} | set(previews)
    if COVER: allowed.add('Cover.png')
    for folder,component in hashes.items():
        base=folder+'/'+component['patch']
        allowed.update({base,base+'.stream',base+'.gpu_resources'})
    base='Glow/WhiteRed/'+light_patch
    allowed.update({base,base+'.stream',base+'.gpu_resources'})
    assert set(files)==allowed,'Unexpected distribution file: '+str(set(files)-allowed)
    report['distribution']={'file_count':len(files),'policy':'runtime_and_referenced_artwork_only',
                            'license':'embedded_in_core_lua','development_files_packaged':False}
    destination = ROOT / 'release' / ('G60-Lock-Line-V' + VERSION + '.zip')
    destination.parent.mkdir(exist_ok=True)
    with ZipFile(destination, 'w') as package:
        for name, data in sorted(files.items()):
            item = ZipInfo(name, (2026, 10, 10, 0, 0, 0))
            item.compress_type, item.external_attr = ZIP_DEFLATED, 0o100644 << 16
            package.writestr(item, data)
    # One necessary package read-back, not a gameplay test.
    with ZipFile(destination) as package:
        assert set(package.namelist()) == set(files)
        assert all(package.read(name) == data for name, data in files.items())
        # Resolve this package's actual three-menu selection, including shared Core.
        manifest = json.loads(package.read('manifest.json'))
        assert [option['Name'] for option in manifest['Options']] == ['目标', '颜色', '发光']
        for group in manifest['Options']:
            for choice in group['SubOptions']:
                assert choice['Image'] in files
                assert package.read(choice['Image']).startswith(b'\x89PNG\r\n\x1a\n')
        # Target presets intentionally share one resource/patch slot. Resolve
        # one choice per menu rather than combining mutually exclusive choices.
        for selection in product(*(option['SubOptions'] for option in manifest['Options'])):
            included = set()
            for option, choice in zip(manifest['Options'], selection):
                included.update(option.get('Include', []))
                included.update(choice['Include'])
            deployed = {}
            for folder in included:
                selected = [name for name in files if name.startswith(folder + '/')]
                assert selected, 'Missing option folder: ' + folder
                for name in selected:
                    if '.patch_' in name:
                        leaf = name.rsplit('/', 1)[1]
                        assert leaf not in deployed, 'Selected patch collision: ' + leaf
                        deployed[leaf] = name
            glow_on=selection[2]['Include']==['Glow/WhiteRed']
            assert len(deployed)==(15 if glow_on else 12)
            assert any(name.endswith(light_patch) for name in deployed.values())==glow_on
    (ROOT / 'build/build-report.json').write_bytes(json_bytes(report))
    print(json.dumps({'package': str(destination), 'bytes': destination.stat().st_size,
                      'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(), 'ingame_tested': USER_VERIFIED,'release_status':CONFIG.get('release_status','test')},
                     ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
