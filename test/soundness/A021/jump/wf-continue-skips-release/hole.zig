// warp-fast: a continue skips the guard's release: the next pass takes the lock again, and the last lock is taken, while it is held.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn each(locks: []const *L, b: *L) void {
    for (locks) |l| {
        var g = l.acquire();
        if (g.value().* == 0) continue;
        g.deinit();
    }
    var gb = b.acquire();
    gb.deinit();
}
