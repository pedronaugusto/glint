// A004: Checked's bare value through a const local and a const alias of it, then given to a
// comparison, loses its checks.
const aegis = @import("aegis");
pub fn f(c: aegis.int.Checked(u32)) bool {
    const x = c.raw();
    const y = x;
    return y > 3;
}
