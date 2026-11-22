// A011: aegis's Duration unwrapped from an optional by .?, its count read through its own API: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn f(d: ?Millis) i64 {
    return d.?.raw();
}
