// A011: aegis's Duration an element of an array literal, its count read through its own API: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn f(a: Millis, b: Millis) i64 {
    const pair = [2]Millis{ a, b };
    return pair[1].raw();
}
