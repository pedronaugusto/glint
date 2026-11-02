const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Holder = struct {
    lock: *L,
    guard: L.Guard = undefined,
    fn take(h: *Holder) *L.Guard {
        h.guard = h.lock.acquire();
        return &h.guard;
    }
};
pub fn both(a: *Holder, b: *L) void {
    const g = a.take();
    g.deinit();
    var h = b.acquire();
    h.deinit();
}
