// A generic writes its parameter into two places with a destructuring assignment: two guards.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn dup(x: anytype, a: *@TypeOf(x), b: *@TypeOf(x)) void {
    a.*, b.* = .{ x, x };
}
pub fn g(l: *L) void {
    var one: L.Guard = undefined;
    var two: L.Guard = undefined;
    dup(l.acquire(), &one, &two);
    one.deinit();
    two.deinit();
}
