// matrix A007: the same break carrying aegis's guard.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io) u32 {
    var cell = made: {
        break :made dep.guarded();
    };
    var guard = cell.acquireUncancelable(io);
    defer guard.deinit(io);
    guard.value().* += 1;
    return guard.value().*;
}
