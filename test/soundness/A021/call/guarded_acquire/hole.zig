// A021 (opt-in): an acquisition no Order ranks.
const aegis = @import("aegis");
pub fn bump(g: *aegis.Guarded(u32)) void {
    var guard = g.acquire();
    defer guard.deinit();
    guard.value().* += 1;
}
