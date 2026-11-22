// A001: a holder a destructure names, its internal field read: a finding.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(s: *const S) u32 {
    const held, _ = .{ s, @as(u32, 0) };
    return held.aegis_material;
}
