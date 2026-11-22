// A001: a holder a var is given, its internal field read: a finding.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(s: *const S) u32 {
    var t: *const S = undefined;
    t = s;
    return t.aegis_material;
}
