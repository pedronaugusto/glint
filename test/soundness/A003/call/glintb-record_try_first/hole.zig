// glint-b: a record's deinit may fail before it releases its guard: on that error the guard is held.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct {
    guard: L.Guard,
    count: u32,
    fn deinit(h: *Held) !void {
        try check(h.count);
        h.guard.deinit();
    }
};
fn check(n: u32) !void {
    if (n > 9) return error.Many;
}
fn lockCounted(l: *L) Held {
    return .{ .guard = l.acquire(), .count = 1 };
}
pub fn f(l: *L) !u32 {
    var held = lockCounted(l);
    defer held.deinit() catch {};
    held.count += 1;
    return held.count;
}
