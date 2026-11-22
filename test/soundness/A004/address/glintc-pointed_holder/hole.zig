// A004: Checked's bare value, its holder reached through a pointer, given to a comparison: a finding.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(p: *const C) bool {
    return p.raw() > 3;
}
