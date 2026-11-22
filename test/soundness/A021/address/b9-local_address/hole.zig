// A021: a local guarded value's address taken, an unranked acquisition through it: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
pub fn count() u32 {
    var local: Counter = .init(0);
    const held = &local;
    var guard = held.acquire();
    defer guard.deinit();
    guard.value().* += 1;
    return guard.value().*;
}
