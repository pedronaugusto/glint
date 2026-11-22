// A011: aegis's Duration reached through a pointer to it, its count read through its own API: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn f(d: Millis) i64 {
    const at = &d;
    return at.raw();
}
