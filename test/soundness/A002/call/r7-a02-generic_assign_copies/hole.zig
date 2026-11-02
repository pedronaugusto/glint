// A generic stores its parameter twice through a pointer: bound to a live guard, it duplicates it.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn dup(x: anytype, out: *[2]@TypeOf(x)) void {
    out[0] = x;
    out[1] = x;
}
pub fn g(l: *L) void {
    var both: [2]L.Guard = undefined;
    dup(l.acquire(), &both);
    both[0].deinit();
    both[1].deinit();
}
