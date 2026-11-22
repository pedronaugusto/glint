// A004: Checked's bare value handed on whole in a deferred statement: none.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(c: C, out: *u32) void {
    defer out.* = c.raw();
}
