// glint-b: a record's deinit releases a copy of its optional guard's payload, not the guard it holds.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct {
    guard: ?L.Guard,
    count: u32,
    fn deinit(h: *Held) void {
        if (h.guard) |g| {
            var copy = g;
            copy.deinit();
        }
    }
};
fn lockCounted(l: *L) Held {
    return .{ .guard = l.acquire(), .count = 1 };
}
pub fn f(l: *L) u32 {
    var held = lockCounted(l);
    defer held.deinit();
    held.count += 1;
    return held.count;
}
