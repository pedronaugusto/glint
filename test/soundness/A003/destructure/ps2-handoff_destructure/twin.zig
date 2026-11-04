// pre-sweep-2 A003 twin: the same hand-off released.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn f(l: *L) u32 {
    var g = l.acquire();
    const n = g.value().*;
    var h, const m = .{ g.handOff(), n };
    h.release();
    return m;
}
