// A021: a guarded value's pointer captured from an optional, an unranked acquisition through it: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
pub fn bump(g: ?*Counter) void {
    if (g) |held| {
    var guard = held.acquire();
    defer guard.deinit();
    guard.value().* += 1;
    }
}
