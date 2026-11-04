// A callee that does not resolve is given the address of a record whose field is a guard: b is taken while a is held.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct { g: L.Guard = undefined, n: u32 = 0 };
pub fn both(lockInto: *const fn (*L, *Held) void, a: *L, b: *L) void {
    var held: Held = .{};
    lockInto(a, &held);
    var h = b.acquire();
    h.deinit();
    held.g.deinit();
}
