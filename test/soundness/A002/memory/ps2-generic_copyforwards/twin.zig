// The generic copies its parameter once: the guard moves into it.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn one(x: anytype, out: *[1]@TypeOf(x)) void {
    @memcpy(out, &[1]@TypeOf(x){x});
}
pub fn g(l: *L) void {
    var held: [1]L.Guard = undefined;
    one(l.acquire(), &held);
    held[0].deinit();
}
