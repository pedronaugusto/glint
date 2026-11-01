// matrix A008: a constant given a key pair a dependency makes holds std's secret key by value; nothing in this file names its type.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(io: std.Io, msg: []const u8) ![64]u8 {
    const kp = dep.newPair(io);
    return (try kp.sign(msg, null)).toBytes();
}
