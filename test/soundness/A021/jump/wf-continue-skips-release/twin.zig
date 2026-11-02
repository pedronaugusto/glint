// warp-fast: the guard's deferred release runs on the continue too.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn each(locks: []const *L, b: *L) void {
    for (locks) |l| {
        var g = l.acquire();
        defer g.deinit();
        if (g.value().* == 0) continue;
        g.value().* -= 1;
    }
    var gb = b.acquire();
    gb.deinit();
}
