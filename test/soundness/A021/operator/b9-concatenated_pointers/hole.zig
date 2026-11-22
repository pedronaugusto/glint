// A021: a guarded value's pointer an element of tuples joined by ++, an unranked acquisition: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
pub fn bump(a: *Counter, b: *Counter) void {
    const both = .{a} ++ .{b};
    const held = both[1];
    var guard = held.acquire();
    defer guard.deinit();
    guard.value().* += 1;
}
