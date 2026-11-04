// pre-sweep-2 A003: a hand-off kept by a destructure of a literal (`var h, const m = .{ g.handOff(), n };`) and never released.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn f(l: *L) u32 {
    var g = l.acquire();
    const n = g.value().*;
    var h, const m = .{ g.handOff(), n };
    _ = &h;
    return m;
}
