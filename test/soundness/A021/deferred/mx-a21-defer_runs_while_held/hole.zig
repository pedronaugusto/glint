// matrix: A021 deferred: a deferred block takes a lock at the exit, before the earlier deferred release of a guard taken after it
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var ga: L.Guard = undefined;
    defer ga.deinit();
    defer {
        var gb = b.acquire();
        gb.deinit();
    }
    ga = a.acquire();
    ga.value().* += 1;
}
