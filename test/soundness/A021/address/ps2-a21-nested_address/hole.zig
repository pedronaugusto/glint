// A callee that does not resolve is given `&g` inside a record literal: b is taken while a is held.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Out = struct { slot: *L.Guard };
pub fn both(lockInto: *const fn (*L, Out) bool, a: *L, b: *L) void {
    var g: L.Guard = undefined;
    if (!lockInto(a, .{ .slot = &g })) return;
    var h = b.acquire();
    h.deinit();
    g.deinit();
}
