// matrix A008: the same variable given the key sealed in aegis's Secret.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(io: std.Io, msg: []const u8) ![64]u8 {
    var kp = dep.sealedPair(io);
    defer kp.deinit();
    return (try kp.expose().sign(msg, null)).toBytes();
}
