// The hand-off released.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn f(l: *L) void {
    var g = l.acquire();
    g.value().* += 1;
    var h = g.handOff();
    h.release();
}
