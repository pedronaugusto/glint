// The helper's optional guard released on every path.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn lock(l: *L, busy: bool) ?L.Guard {
    if (busy) return null;
    return l.acquire();
}
pub fn f(l: *L, busy: bool) void {
    var g = lock(l, busy) orelse return;
    defer g.deinit();
    g.value().* += 1;
}
