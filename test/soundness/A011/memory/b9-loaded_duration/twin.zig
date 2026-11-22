// A011: aegis's Duration loaded through a pointer, its count read through its own API: none.
const aegis = @import("aegis");
const Millis = aegis.units.Duration(.millisecond, i64);
pub fn f(at: *const Millis) i64 {
    const held = at.*;
    return held.raw();
}
