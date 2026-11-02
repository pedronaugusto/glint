// The helper returns the guard; the caller releases it before taking b.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn lockInto(l: *L, out: *L.Guard) void {
    out.* = l.acquire();
}
pub fn both(a: *L, b: *L) void {
    var g: L.Guard = undefined;
    lockInto(a, &g);
    g.deinit();
    var h = b.acquire();
    h.deinit();
}
