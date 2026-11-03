// A generic copies a literal of its parameter twice into memory it is given: two guards.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn dup(x: anytype, out: *[2]@TypeOf(x)) void {
    @memcpy(out, &[2]@TypeOf(x){ x, x });
}
pub fn g(l: *L) void {
    var both: [2]L.Guard = undefined;
    dup(l.acquire(), &both);
    both[0].deinit();
    both[1].deinit();
}
