// A011: aegis's Duration captured from an optional, its count read through its own API: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn f(d: ?Millis) i64 {
    if (d) |held| return held.raw();
    return 0;
}
