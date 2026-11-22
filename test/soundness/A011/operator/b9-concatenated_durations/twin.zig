// A011: aegis's Duration an element of tuples joined by ++, its count read through its own API: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn f(a: Millis, b: Millis) i64 {
    const both = .{a} ++ .{b};
    return both[1].raw();
}
