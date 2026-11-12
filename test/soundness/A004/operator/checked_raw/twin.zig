// A004: the bare value handed on whole is no arithmetic, comparison or narrowing cast.
const aegis = @import("aegis");
pub fn f(c: aegis.int.Checked(u32)) u32 {
    return c.raw();
}
