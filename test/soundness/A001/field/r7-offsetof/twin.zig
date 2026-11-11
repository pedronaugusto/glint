const aegis = @import("aegis");
const G = aegis.Guarded(u32);
pub fn f(g: *G) u32 {
    var guard = g.acquire();
    defer guard.deinit();
    return guard.value().*;
}
