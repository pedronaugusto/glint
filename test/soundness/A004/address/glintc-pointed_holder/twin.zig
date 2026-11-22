// A004: Checked's bare value, its holder reached through a pointer, handed on whole: none.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
pub fn f(p: *const C) u32 {
    return p.raw();
}
