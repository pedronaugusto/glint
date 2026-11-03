// A number splatted: plain data.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn g(l: *L) void {
    var held = l.acquire();
    const both: [2]u32 = @splat(held.value().*);
    held.deinit();
    _ = both;
}
