// matrix: A021 memory: the lock read from a shared slot by @atomicLoad, taken after the first guard is released
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, slot: **L) void {
    var ga = a.acquire();
    ga.deinit();
    const b = @atomicLoad(*L, slot, .acquire);
    var gb = b.acquire();
    defer gb.deinit();
}
