// The generic returns its parameter once in a literal: the guard moves into it.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn one(x: anytype) [1]@TypeOf(x) {
    return .{x};
}
pub fn g(l: *L) void {
    var held = one(l.acquire());
    held[0].deinit();
}
