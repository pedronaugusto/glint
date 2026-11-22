// A001: an optional holder unwrapped, its internal field read: a finding.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(o: ?*const S) u32 {
    return o.?.aegis_material;
}
