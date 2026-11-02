// warp-fast: a return before the guard's release leaves it held while the errdefer takes a second lock.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L, fail: bool) !void {
    errdefer {
        var gb = b.acquire();
        gb.deinit();
    }
    var ga = a.acquire();
    if (fail) return error.Failed;
    ga.deinit();
}
