// A021: an unranked acquisition on an anytype receiver, given aegis's guarded value: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
fn bumpAny(held: anytype) void {
    var guard = held.acquire();
    defer guard.deinit();
    guard.value().* += 1;
}
pub fn bump(g: *Counter) void {
    bumpAny(g);
}
