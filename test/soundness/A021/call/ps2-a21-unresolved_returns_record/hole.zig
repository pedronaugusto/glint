// A callee that does not resolve returns a record holding a's guard: b is taken while held.guard holds a.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct { guard: L.Guard, count: u32 };
pub fn both(lockCounted: *const fn (*L) Held, a: *L, b: *L) void {
    var held = lockCounted(a);
    var h = b.acquire();
    h.deinit();
    held.guard.deinit();
}
