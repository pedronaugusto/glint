// glint-b: a record's deinit releases its own guard through two helpers of its own.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct {
    guard: L.Guard,
    count: u32,
    fn drop(h: *Held) void {
        h.guard.deinit();
    }
    fn releaseAll(h: *Held) void {
        h.drop();
    }
    fn deinit(h: *Held) void {
        h.releaseAll();
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
