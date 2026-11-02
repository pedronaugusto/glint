// A generic stores its parameter once through a pointer: the guard moves there.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn put(x: anytype, out: *@TypeOf(x)) void {
    out.* = x;
}
pub fn g(l: *L) void {
    var held: L.Guard = undefined;
    put(l.acquire(), &held);
    held.deinit();
}
