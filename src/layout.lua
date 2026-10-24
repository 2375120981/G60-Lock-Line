-- Adapted from etxp/HD2-G60-Smart-Targeting (MIT); see THIRD-PARTY-NOTICES.md.
-- Decode only; no pointer is a lifetime lease.
local M = {}
function M.u32(s, offset)
    local a, b, c, d = s:byte(offset + 1, offset + 4)
    assert(d, 'short u32')
    return a + b * 256 + c * 65536 + d * 16777216
end
function M.pointer(s, offset, alignment)
    alignment = alignment or 8
    local high = M.u32(s, offset + 4)
    local address = M.u32(s, offset) + high * 4294967296
    assert(high < 32768 and address >= 65536 and address < 2^47
        and address % alignment == 0, 'pointer bound')
    return address
end
function M.hex64(s, offset)
    return string.format('%08x%08x', M.u32(s, offset + 4), M.u32(s, offset))
end
return M
