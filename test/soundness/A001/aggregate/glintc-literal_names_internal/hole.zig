// A001: a struct literal naming the internal field: a finding.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(v: u32) S {
    return .{ .aegis_material = v };
}
