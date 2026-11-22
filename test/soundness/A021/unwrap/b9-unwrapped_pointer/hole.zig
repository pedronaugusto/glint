// A021: a guarded value's pointer unwrapped from an optional by .?, an unranked acquisition: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
pub fn bump(g: ?*Counter) void {
    const held = g.?;
    var guard = held.acquire();
    defer guard.deinit();
    guard.value().* += 1;
}
