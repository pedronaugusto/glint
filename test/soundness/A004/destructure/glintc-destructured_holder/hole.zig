// A004: Checked's bare value, its holder named by a destructure, given to a comparison: a finding.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(c: C) bool {
    const held, _ = .{ c, @as(u8, 0) };
    return held.raw() > 3;
}
