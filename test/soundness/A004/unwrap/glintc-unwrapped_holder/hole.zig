// A004: Checked's bare value, its holder unwrapped from an optional by .?, given to a comparison: a finding.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(given: ?C) bool {
    return given.?.raw() > 3;
}
