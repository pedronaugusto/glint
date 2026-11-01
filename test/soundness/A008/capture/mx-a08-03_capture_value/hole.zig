// matrix A008: an optional key pair a dependency gives, captured by value.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(io: std.Io, wanted: bool, msg: []const u8) !?[64]u8 {
    if (dep.maybePair(io, wanted)) |kp| return (try kp.sign(msg, null)).toBytes();
    return null;
}
