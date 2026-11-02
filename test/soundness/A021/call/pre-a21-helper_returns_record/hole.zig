// A helper returns a record that holds a guard: the caller holds a while it takes b.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct { guard: L.Guard, count: u32 };
fn lockCounted(l: *L) Held {
    return .{ .guard = l.acquire(), .count = 1 };
}
pub fn both(a: *L, b: *L) void {
    var held = lockCounted(a);
    var h = b.acquire();
    h.deinit();
    held.guard.deinit();
}
