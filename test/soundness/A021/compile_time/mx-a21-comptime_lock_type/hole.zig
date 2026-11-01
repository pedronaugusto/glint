// matrix: A021 compile_time: a generic over a comptime lock type takes two locks at once; the caller names aegis's
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn both(comptime T: type, x: *T, y: *T) void {
    var gx = x.acquire();
    defer gx.deinit();
    var gy = y.acquire();
    defer gy.deinit();
}
pub fn run(a: *L, b: *L) void {
    both(L, a, b);
}
