// matrix A007: the same tuple holding aegis's guard.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io) u32 {
    var held = .{ dep.guarded(), @as(u32, 1) };
    var guard = held[0].acquireUncancelable(io);
    defer guard.deinit(io);
    return guard.value().* + held[1];
}
