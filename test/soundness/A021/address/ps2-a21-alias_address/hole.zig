// A callee that does not resolve writes a's guard through a pointer made beforehand (`const p = &g`): b is taken while a is held.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(lockInto: *const fn (*L, *L.Guard) void, a: *L, b: *L) void {
    var g: L.Guard = undefined;
    const p = &g;
    lockInto(a, p);
    var h = b.acquire();
    h.deinit();
    g.deinit();
}
