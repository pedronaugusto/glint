// A001: an optional's captured holder, its internal field read: a finding.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(o: ?*const S) u32 {
    if (o) |s| return s.aegis_material;
    return 0;
}
