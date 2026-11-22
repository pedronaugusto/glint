// A021: a guarded value's pointer the result of a labeled block, an unranked acquisition: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
pub fn bump(g: *Counter) void {
    const held = blk: {
        break :blk g;
    };
    var guard = held.acquire();
    defer guard.deinit();
    guard.value().* += 1;
}
