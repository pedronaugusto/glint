// matrix A007: the same `try` unwrapping aegis's guard.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io) !u32 {
    var cell = try dep.tryGuarded(true);
    var guard = cell.acquireUncancelable(io);
    defer guard.deinit(io);
    guard.value().* += 1;
    return guard.value().*;
}
