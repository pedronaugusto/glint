// A001: a defer writing the internal field: a finding.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(s: *S) void {
    defer s.aegis_material = 0;
}
