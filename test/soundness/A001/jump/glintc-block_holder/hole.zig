// A001: a labeled block's break gives the holder, its internal field read: a finding.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(s: *const S) u32 {
    const held = blk: {
        break :blk s;
    };
    return held.aegis_material;
}
