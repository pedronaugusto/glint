// glint-b: a helper given the record overwrites its guard before the deinit releases it: the first guard is held.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct {
    guard: L.Guard,
    count: u32,
    lock: *L,
    fn renew(h: *Held) void {
        h.guard = h.lock.acquire();
    }
    fn deinit(h: *Held) void {
        renew(h);
        h.guard.deinit();
    }
};
fn lockCounted(l: *L) Held {
    return .{ .guard = l.acquire(), .count = 1, .lock = l };
}
pub fn f(l: *L) u32 {
    var held = lockCounted(l);
    defer held.deinit();
    held.count += 1;
    return held.count;
}
