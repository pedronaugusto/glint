// A004: Checked's bare value, its holder captured from an optional, handed on whole: none.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(given: ?C) u32 {
    if (given) |c| return c.raw();
    return 0;
}
