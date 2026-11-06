// glint-b: a record's deinit releases its guard in an errdefer only: on its normal return the guard is still held.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct {
    guard: L.Guard,
    count: u32,
    fn deinit(h: *Held) !void {
        errdefer h.guard.deinit();
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
