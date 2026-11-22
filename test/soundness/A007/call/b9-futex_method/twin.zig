// A007: the value set under aegis's guard, its method called on the guard: none.
const aegis = @import("aegis");
pub fn wake(guarded: *aegis.Guarded(u32)) void {
    var guard = guarded.acquire();
    defer guard.deinit();
    guard.value().* = 1;
}
