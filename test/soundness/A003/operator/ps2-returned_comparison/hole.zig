// A helper's optional guard compared in the return: a bool is returned, the guard is never
// released, and the lock stays held.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn lock(l: *L, busy: bool) ?L.Guard {
    if (busy) return null;
    return l.acquire();
}
pub fn f(l: *L, busy: bool) bool {
    const held = lock(l, busy);
    return held != null;
}
