// matrix A008: an `if` chooses which of the dependency's key pairs a constant holds.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(io: std.Io, seed: ?[32]u8, msg: []const u8) ![64]u8 {
    const kp = if (seed) |s| try dep.tryPair(s) else dep.newPair(io);
    return (try kp.sign(msg, null)).toBytes();
}
