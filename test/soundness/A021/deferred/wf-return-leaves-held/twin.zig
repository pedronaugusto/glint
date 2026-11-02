// warp-fast: the guard released before the return the errdefer runs on.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L, fail: bool) !void {
    errdefer {
        var gb = b.acquire();
        gb.deinit();
    }
    var ga = a.acquire();
    ga.deinit();
    if (fail) return error.Failed;
}
