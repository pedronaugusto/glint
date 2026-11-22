// A004: Checked's bare value, its holder a labeled block's result, given to a comparison: a finding.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(c: C) bool {
    const held = blk: {
        break :blk c;
    };
    return held.raw() > 3;
}
