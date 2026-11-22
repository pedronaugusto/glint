// A004: Checked's bare value, its holder an unrolled loop's capture, handed on whole: none.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(a: C, b: C, out: *[2]u32) void {
    inline for (.{ a, b }, 0..) |c, i| out[i] = c.raw();
}
