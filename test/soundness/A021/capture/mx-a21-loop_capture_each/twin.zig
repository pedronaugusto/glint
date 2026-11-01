// matrix: A021 capture: one acquisition in a loop over captured locks, each released in its pass
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn all(locks: [2]*L) void {
    for (locks) |l| {
        var g = l.acquire();
        g.value().* += 1;
        g.deinit();
    }
}
