// matrix: A021 branch: the second lock chosen by an if expression, while the first guard is held
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L, d: *L, c: bool) void {
    var gd = d.acquire();
    defer gd.deinit();
    const l = if (c) a else b;
    var gl = l.acquire();
    defer gl.deinit();
}
