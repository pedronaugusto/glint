// A011: aegis's Duration named by a destructure, its count read through its own API: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn f(d: Millis, n: u8) i64 {
    const held, const other = .{ d, n };
    _ = other;
    return held.raw();
}
