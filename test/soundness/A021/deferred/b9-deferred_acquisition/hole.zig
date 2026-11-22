// A021: an unranked acquisition at the scope's end: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
pub fn finish(held: *Counter) void {
    defer {
    var guard = held.acquire();
    defer guard.deinit();
    guard.value().* += 1;
    }
}
