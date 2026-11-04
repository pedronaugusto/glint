// b is taken and released before the callee takes a into g.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Out = struct { slot: *L.Guard };
pub fn both(lockInto: *const fn (*L, Out) bool, a: *L, b: *L) void {
    var h = b.acquire();
    h.deinit();
    var g: L.Guard = undefined;
    if (!lockInto(a, .{ .slot = &g })) return;
    g.deinit();
}
