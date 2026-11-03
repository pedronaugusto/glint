// The generic writes its parameter once: the guard moves into it.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn put(x: anytype, a: *@TypeOf(x), b: *u32) void {
    a.*, b.* = .{ x, 1 };
}
pub fn g(l: *L) void {
    var one: L.Guard = undefined;
    var n: u32 = 0;
    put(l.acquire(), &one, &n);
    one.deinit();
}
