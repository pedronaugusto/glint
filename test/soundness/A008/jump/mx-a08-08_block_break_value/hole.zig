// matrix A008: a labeled block's break carries the dependency's key pair into a constant.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(io: std.Io, msg: []const u8) ![64]u8 {
    const kp = made: {
        break :made dep.newPair(io);
    };
    return (try kp.sign(msg, null)).toBytes();
}
