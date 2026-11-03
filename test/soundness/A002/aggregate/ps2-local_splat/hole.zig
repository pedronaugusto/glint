// A live guard splatted into an array: two guards of one lock, both released.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn g(l: *L) void {
    var held = l.acquire();
    var both: [2]L.Guard = @splat(held);
    both[0].deinit();
    both[1].deinit();
    _ = &held;
}
