// The local holds the parameter once: the guard moves through it.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn one(x: anytype) [1]@TypeOf(x) {
    const held: [1]@TypeOf(x) = .{x};
    return held;
}
pub fn g(l: *L) void {
    var held = one(l.acquire());
    held[0].deinit();
}
