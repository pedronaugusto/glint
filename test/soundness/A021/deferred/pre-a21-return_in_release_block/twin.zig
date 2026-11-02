const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    defer {
        var h = b.acquire();
        h.deinit();
    }
    var g = a.acquire();
    {
        const zero = g.value().* == 0;
        g.deinit();
        if (zero) return;
    }
}
