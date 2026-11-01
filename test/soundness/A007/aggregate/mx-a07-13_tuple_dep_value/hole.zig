// matrix A007: a tuple literal holds the dependency's lock beside a count.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io) u32 {
    var held = .{ dep.make(), @as(u32, 1) };
    held[0].lockUncancelable(io);
    defer held[0].unlock(io);
    return held[1];
}
