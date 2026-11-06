// glint-b: a record's own deinit releases its guard on one branch only: the guard may be held past it.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct {
    guard: L.Guard,
    count: u32,
    fn deinit(h: *Held, done: bool) void {
        if (done) h.guard.deinit();
    }
};
fn lockCounted(l: *L) Held {
    return .{ .guard = l.acquire(), .count = 1 };
}
pub fn f(l: *L) u32 {
    var held = lockCounted(l);
    defer held.deinit(held.count > 1);
    held.count += 1;
    return held.count;
}
