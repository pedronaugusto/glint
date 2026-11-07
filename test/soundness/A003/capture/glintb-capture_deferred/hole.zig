// glint-b: a record released in its pointer capture outside a defer, an early return before it leaves it held.
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
    var maybe = maybeLock(l, take);
    if (maybe) |*held| {
        if (held.count > 9) return 0;
        held.count += 1;
        held.deinit();
    }
    return 0;
}
