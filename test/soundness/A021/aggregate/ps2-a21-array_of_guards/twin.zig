// b is taken and released before the callee takes a into the array.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(lockAll: *const fn (*L, *[1]L.Guard) void, a: *L, b: *L) void {
    var h = b.acquire();
    h.deinit();
    var gs: [1]L.Guard = undefined;
    lockAll(a, &gs);
    gs[0].deinit();
}
