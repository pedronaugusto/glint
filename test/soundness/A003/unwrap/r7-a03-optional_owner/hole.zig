// A guard the program's helper gives as an optional is never released: the lock stays held.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn lock(l: *L, busy: bool) ?L.Guard {
    if (busy) return null;
    return l.acquire();
}
pub fn f(l: *L, busy: bool) void {
    var g = lock(l, busy) orelse return;
    g.value().* += 1;
}
