// The record's guard is released before b is taken.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct { guard: L.Guard, count: u32 };
fn lockCounted(l: *L) Held {
    return .{ .guard = l.acquire(), .count = 1 };
}
pub fn both(a: *L, b: *L) void {
    var held = lockCounted(a);
    held.guard.deinit();
    var h = b.acquire();
    h.deinit();
}
