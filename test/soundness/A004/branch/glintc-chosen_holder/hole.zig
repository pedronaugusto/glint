// A004: Checked's bare value, its holder chosen by an if, given to a comparison: a finding.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(first: bool, a: C, b: C) bool {
    return (if (first) a else b).raw() > 3;
}
