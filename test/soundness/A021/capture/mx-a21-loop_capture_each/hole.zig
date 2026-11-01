// matrix: A021 capture: one acquisition in a loop over captured locks, each guard kept through a captured pointer: every lock held at once
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn all(locks: [2]*L) void {
    var guards: [2]L.Guard = undefined;
    for (locks, &guards) |l, *g| g.* = l.acquire();
    for (&guards) |*g| g.deinit();
}
