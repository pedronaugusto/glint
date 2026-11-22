// A021: a guarded value's pointer copied into a const, an unranked acquisition through it: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
pub fn bump(g: *Counter) void {
    const held = g;
    var guard = held.acquire();
    defer guard.deinit();
    guard.value().* += 1;
}
