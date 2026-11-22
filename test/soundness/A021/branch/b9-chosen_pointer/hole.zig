// A021: a guarded value's pointer chosen by an if, an unranked acquisition through it: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
pub fn bump(first: bool, a: *Counter, b: *Counter) void {
    const held = if (first) a else b;
    var guard = held.acquire();
    defer guard.deinit();
    guard.value().* += 1;
}
