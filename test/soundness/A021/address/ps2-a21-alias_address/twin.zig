// b is taken and released before the callee takes a into g.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(lockInto: *const fn (*L, *L.Guard) void, a: *L, b: *L) void {
    var h = b.acquire();
    h.deinit();
    var g: L.Guard = undefined;
    const p = &g;
    lockInto(a, p);
    g.deinit();
}
