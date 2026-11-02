// The return inside the block that holds the release leaves a's guard held while the earlier defer takes b.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    defer {
        var h = b.acquire();
        h.deinit();
    }
    var g = a.acquire();
    {
        if (g.value().* == 0) return;
        g.deinit();
    }
}
