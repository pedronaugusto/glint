// A007: aegis named by a destructure, its guard reached through it: none.
const aegis = @import("aegis");
const std = @import("std");
pub fn make() u32 {
    const sync, const mem = .{ aegis, std.mem };
    _ = mem;
    var guarded: sync.Guarded(u32) = .init(0);
    var guard = guarded.acquire();
    defer guard.deinit();
    return guard.value().*;
}
