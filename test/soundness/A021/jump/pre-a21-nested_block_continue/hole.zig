// A continue inside the block that holds the release skips it: the next pass takes the next lock while this one is held.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn each(locks: []const *L, b: *L) void {
    for (locks) |l| {
        var g = l.acquire();
        {
            if (g.value().* == 0) continue;
            g.deinit();
        }
    }
    var gb = b.acquire();
    gb.deinit();
}
