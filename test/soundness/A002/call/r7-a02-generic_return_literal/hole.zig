// A generic returns its parameter twice in a literal: bound to a live guard, it duplicates the
// guard, and both copies are released. A non-generic of the same body is flagged.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn dup(x: anytype) [2]@TypeOf(x) {
    return .{ x, x };
}
pub fn g(l: *L) void {
    var both = dup(l.acquire());
    both[0].deinit();
    both[1].deinit();
}
