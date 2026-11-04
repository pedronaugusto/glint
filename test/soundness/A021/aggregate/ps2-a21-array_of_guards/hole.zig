// A callee that does not resolve takes a into an array of guards it is given the address of: b is taken while gs[0] holds a.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(lockAll: *const fn (*L, *[1]L.Guard) void, a: *L, b: *L) void {
    var gs: [1]L.Guard = undefined;
    lockAll(a, &gs);
    var h = b.acquire();
    h.deinit();
    gs[0].deinit();
}
