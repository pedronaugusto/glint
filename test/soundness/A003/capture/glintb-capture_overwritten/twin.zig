// glint-b: a record released through its pointer capture, the local set only after.
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
pub fn f(l: *L, take: bool) void {
    var maybe = maybeLock(l, take);
    if (maybe) |*held| held.deinit();
    maybe = null;
}
