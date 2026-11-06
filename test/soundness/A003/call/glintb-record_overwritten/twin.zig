// glint-b: a helper given the record only reads it before the deinit releases its guard.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct {
    guard: L.Guard,
    count: u32,
    lock: *L,
    fn total(h: *const Held) u32 {
        return h.count;
    }
    fn deinit(h: *Held) void {
        _ = total(h);
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
