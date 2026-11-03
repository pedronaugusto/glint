// The guard released before the bool is returned.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn lock(l: *L, busy: bool) ?L.Guard {
    if (busy) return null;
    return l.acquire();
}
pub fn f(l: *L, busy: bool) bool {
    var held = lock(l, busy) orelse return false;
    held.deinit();
    return true;
}
