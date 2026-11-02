// a's guard is released before b is tried.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const R = aegis.SpinRwGuarded(u32);
pub fn both(a: *L, b: *R) void {
    var g = a.acquire();
    g.deinit();
    if (b.tryWrite()) |w| {
        var held = w;
        held.deinit();
    }
}
