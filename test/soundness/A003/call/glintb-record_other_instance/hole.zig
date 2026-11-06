// glint-b: a record's method releases another record's guard, not its own: its own is held past it.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct {
    guard: L.Guard,
    count: u32,
    fn dropOther(h: *Held, other: *Held) void {
        h.count = 0;
        other.guard.deinit();
    }
};
fn lockCounted(l: *L) Held {
    return .{ .guard = l.acquire(), .count = 1 };
}
pub fn f(l: *L, spare: *Held) u32 {
    var held = lockCounted(l);
    defer held.dropOther(spare);
    held.count += 1;
    return held.count;
}
