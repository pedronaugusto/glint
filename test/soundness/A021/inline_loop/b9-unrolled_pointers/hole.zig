// A021: guarded values' pointers an unrolled loop's capture, an unranked acquisition each: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
pub fn bump(a: *Counter, b: *Counter) void {
    inline for (.{ a, b }) |held| {
    var guard = held.acquire();
    defer guard.deinit();
    guard.value().* += 1;
    }
}
