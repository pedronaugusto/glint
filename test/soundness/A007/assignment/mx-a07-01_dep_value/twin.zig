// matrix A007: the same variable given aegis's guard, which holds the data it guards.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io) u32 {
    var cell = dep.guarded();
    var guard = cell.acquireUncancelable(io);
    defer guard.deinit(io);
    guard.value().* += 1;
    return guard.value().*;
}
