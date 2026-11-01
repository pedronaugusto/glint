// matrix: A021 branch: an if expression takes one lock or the other, never both
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn one(a: *L, b: *L, c: bool) void {
    var g = if (c) a.acquire() else b.acquire();
    defer g.deinit();
    g.value().* += 1;
}
