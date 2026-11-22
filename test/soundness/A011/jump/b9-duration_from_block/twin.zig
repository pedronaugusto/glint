// A011: aegis's Duration the result of a labeled block, its count read through its own API: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn f(d: Millis) i64 {
    const held = blk: {
        break :blk d;
    };
    return held.raw();
}
