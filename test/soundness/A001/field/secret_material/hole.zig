// A001: a read of Secret's internal field outside aegis is a finding.
const aegis = @import("aegis");
pub fn f(s: *const aegis.Secret(u32)) u32 {
    return s.aegis_material;
}
