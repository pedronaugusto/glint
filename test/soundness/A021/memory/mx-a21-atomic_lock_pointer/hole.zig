// matrix: A021 memory: the second lock's pointer read from a shared slot by @atomicLoad, while the first guard is held
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, slot: **L) void {
    var ga = a.acquire();
    defer ga.deinit();
    const b = @atomicLoad(*L, slot, .acquire);
    var gb = b.acquire();
    defer gb.deinit();
}
