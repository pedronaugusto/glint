// matrix A008: a tuple literal holds the dependency's key pair beside a count.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(io: std.Io, msg: []const u8) ![64]u8 {
    const held = .{ dep.newPair(io), @as(u32, 0) };
    return (try held[0].sign(msg, null)).toBytes();
}
