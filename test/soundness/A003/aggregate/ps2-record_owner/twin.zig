// The record's guard released.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct { guard: L.Guard, count: u32 };
fn lockCounted(l: *L) Held {
    return .{ .guard = l.acquire(), .count = 1 };
}
pub fn f(l: *L) u32 {
    var held = lockCounted(l);
    defer held.guard.deinit();
    held.count += 1;
    return held.count;
}
