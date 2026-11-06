// glint-b: a record an acquisition gives as an optional, unwrapped by orelse, is released as one held by value; null returns holding nothing.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct {
    guard: L.Guard,
    count: u32,
    fn deinit(h: *Held) void {
        h.guard.deinit();
    }
};
fn maybeLock(l: *L, take: bool) ?Held {
    if (!take) return null;
    return .{ .guard = l.acquire(), .count = 1 };
}
pub fn f(l: *L, take: bool) u32 {
    var held = maybeLock(l, take) orelse return 0;
    defer held.deinit();
    held.count += 1;
    return held.count;
}
