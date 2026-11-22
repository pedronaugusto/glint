// A007: a guard released at the scope's end, through an alias: none.
const aegis = @import("aegis");
const sync = aegis;
pub fn finish(guarded: *sync.Guarded(u32)) void {
    var guard = guarded.acquire();
    defer guard.deinit();
    guard.value().* = 1;
}
