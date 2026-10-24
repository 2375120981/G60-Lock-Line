"""Own marker Unit and HDR child materials for the resident standard shader.

Material template is a 592-byte installed-game child, not a third-party mod.
It is copied under new IDs; no original Unit or material resource is replaced.
"""
import hashlib
from pathlib import Path
import struct
from light_asset import light_unit, UNIT_TYPE, LIGHT_RESOURCE

MATERIAL_TYPE = 0xEAC0B497876ADEDF
MARKER_RESOURCE = 'units/c09nat/g60_bloom_marker'
WHITE_MATERIAL = 'materials/c09nat/g60_bloom_white'
RED_MATERIAL = 'materials/c09nat/g60_bloom_red'
TEMPLATE = Path(__file__).resolve().parents[1] / 'assets/bloom-template.material'
TEMPLATE_SHA = '056c028440d50fa88da5c033ab0d9e03c1f7d7afdd91de072bef54a5971b60a5'


def marker_unit(hash64):
    data = bytearray(light_unit(hash64))
    # Same validated identity root, with zero lights and no static mesh/physics.
    data[144:272] = b'\0' * 128
    return bytes(data)


def material(color, strength=32):
    data = bytearray(TEMPLATE.read_bytes())
    assert hashlib.sha256(data).hexdigest() == TEMPLATE_SHA
    assert len(data) == 592
    assert struct.unpack_from('<Q', data, 24)[0] == 0x125D585889A0CFBA
    assert struct.unpack_from('<I', data, 104)[0] == 14
    # Validate descriptors, not only absolute offsets, before changing values.
    variables = {}
    for i in range(14):
        kind, count, name, offset, stride = struct.unpack_from('<5I', data, 208+i*20)
        variables[name] = (kind, 488+offset)
    for name, kind, values in [(0x02F6DC5B, 0, [strength]), (0x12A0F5C0, 2, color),
                               (0x7DA4D360, 0, [0]), (0xEA2298B5, 0, [1]),
                               (0xCB577B8F, 2, [0, 0, 0])]:
        actual_kind, at = variables[name]
        assert actual_kind == kind and at+len(values)*4 <= len(data)
        struct.pack_into('<'+'f'*len(values), data, at, *values)
    return bytes(data)


def resources(hash64):
    return [(LIGHT_RESOURCE, UNIT_TYPE, light_unit(hash64)),
            (MARKER_RESOURCE, UNIT_TYPE, marker_unit(hash64)),
            (WHITE_MATERIAL, MATERIAL_TYPE, material([1, 1, 1])),
            (RED_MATERIAL, MATERIAL_TYPE, material([1, 0, 0]))]


def asset_archive(hash64):
    entries = resources(hash64)
    types = sorted({t for _, t, _ in entries})
    entries.sort(key=lambda row: (row[1], hash64(row[0].encode())))
    offset = (72+32*len(types)+80*len(entries)+15) & ~15
    length = offset+sum((len(body)+15) & ~15 for _, _, body in entries)
    data = bytearray(length)
    struct.pack_into('<III20sQQ24s', data, 0, 0xF0000011, len(types), len(entries), b'', length, 0, b'')
    for i, kind in enumerate(types):
        count = sum(t == kind for _, t, _ in entries)
        struct.pack_into('<IIQIIII', data, 72+i*32, 0, 0, kind, count, 0, 16, 16)
    for i, (name, kind, body) in enumerate(entries):
        struct.pack_into('<7Q6I', data, 72+32*len(types)+i*80, hash64(name.encode()), kind,
                         offset, 0, 0, 0, 0, len(body), 0, 0, 16, 16, 0)
        data[offset:offset+len(body)] = body
        offset += (len(body)+15) & ~15
    return bytes(data)
