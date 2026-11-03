// A generic's local holds its parameter twice in a literal, then returns it: bound to a live
// guard, two guards of one lock, both released. `return .{ x, x }` is flagged.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn dup(x: anytype) [2]@TypeOf(x) {
    const both: [2]@TypeOf(x) = .{ x, x };
    return both;
}
pub fn g(l: *L) void {
    var both = dup(l.acquire());
    both[0].deinit();
    both[1].deinit();
}
