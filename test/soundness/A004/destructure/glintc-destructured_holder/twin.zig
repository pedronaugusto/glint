// A004: Checked's bare value, its holder named by a destructure, handed on whole: none.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(c: C) u32 {
    const held, _ = .{ c, @as(u8, 0) };
    return held.raw();
}
