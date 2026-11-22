// A007: aegis reached through a pointer to it, its guard made: none.
const aegis = @import("aegis");
const sync = &aegis;
pub fn make() u32 {
    var guarded: sync.*.Guarded(u32) = .init(0);
    var guard = guarded.acquire();
    defer guard.deinit();
    return guard.value().*;
}
