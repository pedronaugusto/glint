// A guard handed off into a local Handoff that is never released nor handed on: the lock is
// held for good. aegis says a hand-off is released exactly once.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn f(l: *L) void {
    var g = l.acquire();
    g.value().* += 1;
    var h = g.handOff();
    _ = &h;
}
