// matrix A007: the same `if` choosing aegis's guard.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io, fresh: bool) u32 {
    var cell = if (fresh) dep.guarded() else dep.guarded();
    var guard = cell.acquireUncancelable(io);
    defer guard.deinit(io);
    guard.value().* += 1;
    return guard.value().*;
}
