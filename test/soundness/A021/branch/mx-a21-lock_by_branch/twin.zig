// matrix: A021 branch: the lock chosen by an if expression, taken after the first guard is released
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L, d: *L, c: bool) void {
    var gd = d.acquire();
    gd.deinit();
    const l = if (c) a else b;
    var gl = l.acquire();
    defer gl.deinit();
}
