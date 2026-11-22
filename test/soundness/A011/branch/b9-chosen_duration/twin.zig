// A011: aegis's Duration chosen by an if, its count read through its own API: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn f(first: bool, a: Millis, b: Millis) i64 {
    return (if (first) a else b).raw();
}
