// matrix: A021 call: two locks taken at once through anytype parameters, the caller passing aegis locks
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn both(x: anytype, y: anytype) void {
    var gx = x.acquire();
    defer gx.deinit();
    var gy = y.acquire();
    defer gy.deinit();
}
pub fn run(a: *L, b: *L) void {
    both(a, b);
}
