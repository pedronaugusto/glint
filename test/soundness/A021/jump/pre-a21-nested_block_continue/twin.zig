// The release runs before the continue.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn each(locks: []const *L, b: *L) void {
    for (locks) |l| {
        var g = l.acquire();
        {
            const zero = g.value().* == 0;
            g.deinit();
            if (zero) continue;
        }
    }
    var gb = b.acquire();
    gb.deinit();
}
