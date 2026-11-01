// matrix A008: @call makes the dependency's key pair: the constant holds it by value.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(io: std.Io, msg: []const u8) ![64]u8 {
    const kp = @call(.auto, dep.newPair, .{io});
    return (try kp.sign(msg, null)).toBytes();
}
