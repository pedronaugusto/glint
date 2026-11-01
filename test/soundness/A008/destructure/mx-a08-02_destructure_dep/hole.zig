// matrix A008: a destructure takes a key pair out of a dependency's tuple.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(io: std.Io, msg: []const u8) ![64]u8 {
    const kp, const uses = dep.pair(io);
    _ = uses;
    return (try kp.sign(msg, null)).toBytes();
}
