// A021: a guarded value a struct's field, an unranked acquisition through the field: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
pub const Stats = struct { count: Counter };
pub fn bump(s: *Stats) void {
    const held = &s.count;
    var guard = held.acquire();
    defer guard.deinit();
    guard.value().* += 1;
}
