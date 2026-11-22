// A004: Checked's bare value, its holder a comptime constant, given to a comparison: a finding.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
const limit: C = .init(9);
pub fn f(n: u32) bool {
    return limit.raw() > n;
}
