// A generic moves its parameter into a slot, but the caller's argument is its own live guard:
// the slot and the local are two guards of one lock, and both are released.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn put(x: anytype, out: *@TypeOf(x)) void {
    out.* = x;
}
pub fn g(l: *L) void {
    var held = l.acquire();
    var slot: L.Guard = undefined;
    put(held, &slot);
    slot.deinit();
    held.deinit();
}
