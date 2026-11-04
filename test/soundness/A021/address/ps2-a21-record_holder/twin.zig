// b is taken and released before the callee takes a into the record.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct { g: L.Guard = undefined, n: u32 = 0 };
pub fn both(lockInto: *const fn (*L, *Held) void, a: *L, b: *L) void {
    var h = b.acquire();
    h.deinit();
    var held: Held = .{};
    lockInto(a, &held);
    held.g.deinit();
}
