// A generic moves its parameter into a slot; the caller passes the same live guard each pass,
// so every slot holds a guard of one lock, and each is released.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn put(x: anytype, out: *@TypeOf(x)) void {
    out.* = x;
}
pub fn g(l: *L) void {
    const held = l.acquire();
    var slots: [2]L.Guard = undefined;
    for (&slots) |*slot| put(held, slot);
    for (&slots) |*slot| slot.deinit();
}
