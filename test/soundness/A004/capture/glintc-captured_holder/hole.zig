// A004: Checked's bare value, its holder captured from an optional, given to a comparison: a finding.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(given: ?C) bool {
    if (given) |c| return c.raw() > 3;
    return false;
}
