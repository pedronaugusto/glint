// A007: the value read under aegis's guard: none.
const aegis = @import("aegis");
pub fn read(guarded: *aegis.Guarded(u32)) u32 {
    var guard = guarded.acquire();
    defer guard.deinit();
    return guard.value().*;
}
