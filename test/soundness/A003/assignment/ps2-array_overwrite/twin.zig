// pre-sweep-2 A003 twin: the element released before it is overwritten; every element released by a loop.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn lockBoth(a: *L, b: *L) [2]L.Guard {
    return .{ a.acquire(), b.acquire() };
}
pub fn f(a: *L, b: *L, c: *L) void {
    var gs = lockBoth(a, b);
    gs[0].deinit();
    gs[0] = c.acquire();
    for (&gs) |*g| g.deinit();
}
