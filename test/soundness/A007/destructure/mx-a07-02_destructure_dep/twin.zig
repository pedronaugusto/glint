// matrix A007: the same destructure taking aegis's guard.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io) u32 {
    var cell, const n = dep.guardedPair();
    var guard = cell.acquireUncancelable(io);
    defer guard.deinit(io);
    return guard.value().* + n;
}
