// A011: aegis's Duration converted by @as, its count read through its own API: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn f(d: Millis) i64 {
    return @as(Millis, d).raw();
}
