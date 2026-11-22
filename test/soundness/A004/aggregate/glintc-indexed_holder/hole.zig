// A004: Checked's bare value, its holder an array's element, given to a comparison: a finding.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(pair: [2]C) bool {
    return pair[1].raw() > 3;
}
