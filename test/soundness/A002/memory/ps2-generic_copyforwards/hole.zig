// A generic fills memory it is given from a literal of its parameter with std's copyForwards.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn dup(x: anytype, out: []@TypeOf(x)) void {
    const src = [2]@TypeOf(x){ x, x };
    std.mem.copyForwards(@TypeOf(x), out, &src);
}
pub fn g(l: *L) void {
    var both: [2]L.Guard = undefined;
    dup(l.acquire(), &both);
    both[0].deinit();
    both[1].deinit();
}
