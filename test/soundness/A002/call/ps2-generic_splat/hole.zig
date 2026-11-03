// A generic splats its parameter into an array: bound to a live guard, it duplicates the guard
// (Zig's @splat fills an array of any element type), and both copies are released.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn dup(x: anytype) [2]@TypeOf(x) {
    return @splat(x);
}
pub fn g(l: *L) void {
    var both = dup(l.acquire());
    both[0].deinit();
    both[1].deinit();
}
