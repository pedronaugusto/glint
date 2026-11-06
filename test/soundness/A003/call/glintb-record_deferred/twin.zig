// glint-b: a record's deinit releases its guard in a defer, on every exit, the error one included.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct {
    guard: L.Guard,
    count: u32,
    fn deinit(h: *Held) !void {
        defer h.guard.deinit();
        if (h.count > 9) return error.Many;
    }
};
fn lockCounted(l: *L) Held {
    return .{ .guard = l.acquire(), .count = 1 };
}
pub fn f(l: *L) !u32 {
    var held = lockCounted(l);
    defer held.deinit() catch {};
    held.count += 1;
    return held.count;
}
