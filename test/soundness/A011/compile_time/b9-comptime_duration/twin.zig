// A011: a comptime parameter's aegis Duration, its count read through its own API: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
fn count(comptime d: Millis) i64 {
    return d.raw();
}
pub fn f() i64 {
    return count(Millis.fromRaw(5));
}
