// A001: the internal field's address taken: a finding.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(s: *const S) u32 {
    const p = &s.aegis_material;
    return p.*;
}
