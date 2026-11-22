// A021: a guarded value's pointer loaded through a pointer, an unranked acquisition: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
pub fn bump(at: *const *Counter) void {
    const held = at.*;
    var guard = held.acquire();
    defer guard.deinit();
    guard.value().* += 1;
}
