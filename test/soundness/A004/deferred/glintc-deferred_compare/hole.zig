// A004: Checked's bare value given to arithmetic in a deferred statement: a finding.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(c: C, out: *u32) void {
    defer out.* = c.raw() + 1;
}
