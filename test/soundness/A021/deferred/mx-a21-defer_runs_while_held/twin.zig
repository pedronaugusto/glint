// matrix: A021 deferred: the deferred block that takes a lock runs after the guard's deferred release
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var ga: L.Guard = undefined;
    defer {
        var gb = b.acquire();
        gb.deinit();
    }
    defer ga.deinit();
    ga = a.acquire();
    ga.value().* += 1;
}
