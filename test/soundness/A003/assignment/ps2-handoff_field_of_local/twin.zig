// The record's hand-off released.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Box = struct { h: L.Handoff = undefined, n: u32 = 0 };
pub fn f(l: *L) u32 {
    var box: Box = .{};
    var g = l.acquire();
    box.n = g.value().*;
    box.h = g.handOff();
    box.h.release();
    return box.n;
}
