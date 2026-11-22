// A004: Checked's bare value, its holder loaded from a slice in memory, given to a comparison: a finding.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(items: []const C) bool {
    return items[0].raw() > 3;
}
