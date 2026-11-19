// A004: Checked's bare values held in const locals, then given to arithmetic, lose their checks
// as `a.raw() + b.raw()` would.
const aegis = @import("aegis");
pub fn f(a: aegis.int.Checked(u32), b: aegis.int.Checked(u32)) u32 {
    const x = a.raw();
    const y = b.raw();
    return x + y;
}
