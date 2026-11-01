// matrix A008: the same `if` choosing the sealed key.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(io: std.Io, seed: ?[32]u8, msg: []const u8) ![64]u8 {
    var kp = if (seed) |s| try dep.trySealed(s) else dep.sealedPair(io);
    defer kp.deinit();
    return (try kp.expose().sign(msg, null)).toBytes();
}
