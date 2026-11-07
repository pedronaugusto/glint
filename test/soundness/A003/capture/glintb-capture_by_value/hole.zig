// glint-b: a copy of the record a by-value capture takes is released, which A003 reads as a copy, not the local's record.
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
    const maybe = maybeLock(l, take);
    if (maybe) |held| {
        var copy = held;
        copy.deinit();
    }
}
