// glint-b: a record's deinit releases its optional guard where it holds one, and clears it.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct {
    guard: ?L.Guard,
    count: u32,
    fn deinit(h: *Held) void {
        if (h.guard) |*g| {
            g.deinit();
            h.guard = null;
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
