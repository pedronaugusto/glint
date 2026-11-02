// A helper acquires into the caller's guard through a pointer: the caller holds a while it takes b.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn lockInto(l: *L, out: *L.Guard) void {
    out.* = l.acquire();
}
pub fn both(a: *L, b: *L) void {
    var g: L.Guard = undefined;
    lockInto(a, &g);
    var h = b.acquire();
    h.deinit();
    g.deinit();
}
