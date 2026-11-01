// matrix: A021 conversion: the second lock's receiver an @as of the lock pointer, while the first guard is held
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var ga = a.acquire();
    defer ga.deinit();
    var gb = @as(*L, b).acquire();
    defer gb.deinit();
}
