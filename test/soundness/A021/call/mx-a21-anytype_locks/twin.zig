// matrix: A021 call: two locks taken in turn through anytype parameters
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn both(x: anytype, y: anytype) void {
    var gx = x.acquire();
    gx.deinit();
    var gy = y.acquire();
    gy.deinit();
}
pub fn run(a: *L, b: *L) void {
    both(a, b);
}
