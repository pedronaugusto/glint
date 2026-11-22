// A011: aegis's Duration's count, its own method called: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn f(d: Millis) i64 {
    return d.raw();
}
