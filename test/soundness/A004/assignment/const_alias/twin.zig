// A004: the alias handed on whole is no arithmetic, comparison or narrowing cast.
const aegis = @import("aegis");
pub fn f(c: aegis.int.Checked(u32)) u32 {
    const x = c.raw();
    const y = x;
    return y;
}
