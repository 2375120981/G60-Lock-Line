"""Original meshless omni-light Unit, using the reviewed current compiled layout.

Layout evidence: research/lighting, SDK commit 5a886256e54db52b5d228335eae20ce796f87fc0
and installed boot reflection-probe Unit (version 10800438). No donor geometry,
material, GPU data or third-party mod asset is copied into this generated Unit.
"""
import struct

UNIT_TYPE = 0xE0A48D0BE9A7453F
LIGHT_RESOURCE = 'units/c09nat/g60_status_light'


def light_unit(hash64):
    # 128-byte header, 16-byte empty pre-light section, one 112-byte light,
    # empty LOD list and a single identity root transform. Optional mesh,
    # physics, bones, animation and material sections all have null offsets.
    data = bytearray(448)
    struct.pack_into('<7I', data, 0x28, 2, 10800438, 272, 288, 144, 128, 0)
    struct.pack_into('<4I', data, 144, 1, 0, 0, 0)
    values = [1, 1, 1, 8, 0.1, 2, 1, 0, 0, 0, 0.4, 0, 0, 0, 0, 0]
    # Direct lighting only (0x40), no cast-shadow/disabled/fog flags; type 0=omni.
    struct.pack_into('<II16fB3xI32s', data, 160, hash64(b'g60_status') >> 32, 0,
                     *values, 0x40, 0, b'\0' * 32)
    struct.pack_into('<4I', data, 288, 1, 0, 0, 0)
    local = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0]
    world = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    struct.pack_into('<16f16fHHI', data, 304, *local, *world, 0, 0, hash64(b'root') >> 32)
    return bytes(data)


def unit_archive(hash64):
    unit = light_unit(hash64)
    data = bytearray(192 + len(unit))
    struct.pack_into('<III20sQQ24s', data, 0, 0xF0000011, 1, 1, b'', len(data), 0, b'')
    struct.pack_into('<IIQIIII', data, 72, 0, 0, UNIT_TYPE, 1, 0, 16, 16)
    struct.pack_into('<7Q6I', data, 104, hash64(LIGHT_RESOURCE.encode()), UNIT_TYPE,
                     192, 0, 0, 0, 0, len(unit), 0, 0, 16, 16, 0)
    data[192:] = unit
    return bytes(data)
