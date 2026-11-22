// A021: a guarded value's pointer named by a destructure, an unranked acquisition through it: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
pub fn bump(g: *Counter, n: u8) void {
    const held, const other = .{ g, n };
    _ = other;
    var guard = held.acquire();
    defer guard.deinit();
    guard.value().* += 1;
}
