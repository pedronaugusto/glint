// A001: @field with the internal field's name a comptime constant holds: a finding.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
const name = "aegis_material";
pub fn f(s: *const S) u32 {
    return @field(s, name);
}
