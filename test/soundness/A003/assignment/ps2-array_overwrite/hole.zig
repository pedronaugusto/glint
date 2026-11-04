// pre-sweep-2 A003: an array of guards a helper returns, one element overwritten by a new acquisition while it still holds its guard.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn lockBoth(a: *L, b: *L) [2]L.Guard {
    return .{ a.acquire(), b.acquire() };
}
pub fn f(a: *L, b: *L, c: *L) void {
    var gs = lockBoth(a, b);
    gs[0] = c.acquire();
    for (&gs) |*g| g.deinit();
}
