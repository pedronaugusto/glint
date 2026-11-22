// A021: a function generic over the lock's type, given aegis's guarded value: an unranked
// acquisition its instance makes: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
fn bumpAny(comptime Lock: type, held: *Lock) void {
    var guard = held.acquire();
    defer guard.deinit();
    guard.value().* += 1;
}
pub fn bump(g: *Counter) void {
    bumpAny(Counter, g);
}
