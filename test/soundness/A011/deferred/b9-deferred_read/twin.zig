// A011: aegis's Duration's count read through its own API at the scope's end: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn f(d: Millis, total: *i64) void {
    defer total.* += d.raw();
}
