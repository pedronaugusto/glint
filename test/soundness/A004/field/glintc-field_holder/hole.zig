// A004: Checked's bare value, its holder a struct's field, given to a comparison: a finding.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
const S = struct { count: C };
pub fn f(s: S) bool {
    return s.count.raw() > 3;
}
