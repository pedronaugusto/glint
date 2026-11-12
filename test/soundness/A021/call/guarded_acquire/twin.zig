// A021: the same acquisition inside the seam the project declares for it is no finding.
const aegis = @import("aegis");
pub fn bump(g: *aegis.Guarded(u32)) void {
    var guard = g.acquire();
    defer guard.deinit();
    guard.value().* += 1;
}
