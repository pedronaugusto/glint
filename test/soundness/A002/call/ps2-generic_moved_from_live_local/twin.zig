// The caller hands the generic a guard made in place: the slot is its one holder.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn put(x: anytype, out: *@TypeOf(x)) void {
    out.* = x;
}
pub fn g(l: *L) void {
    var slot: L.Guard = undefined;
    put(l.acquire(), &slot);
    slot.deinit();
}
