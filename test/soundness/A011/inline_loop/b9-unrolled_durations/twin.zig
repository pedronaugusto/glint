// A011: aegis's Durations an unrolled loop's capture, each one's count read through its own API: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn f(a: Millis, b: Millis) i64 {
    var total: i64 = 0;
    inline for (.{ a, b }) |held| total += held.raw();
    return total;
}
