// Each pass passes a guard it acquires: one guard per slot.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn put(x: anytype, out: *@TypeOf(x)) void {
    out.* = x;
}
pub fn g(ls: *[2]L) void {
    var slots: [2]L.Guard = undefined;
    for (&slots, ls) |*slot, *l| put(l.acquire(), slot);
    for (&slots) |*slot| slot.deinit();
}
