// A021: a guarded value's pointer an element of an array literal, an unranked acquisition: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
pub fn bump(a: *Counter, b: *Counter) void {
    const pair = [2]*Counter{ a, b };
    const held = pair[1];
    var guard = held.acquire();
    defer guard.deinit();
    guard.value().* += 1;
}
