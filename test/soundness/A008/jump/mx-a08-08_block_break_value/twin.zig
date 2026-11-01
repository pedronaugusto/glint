// matrix A008: the same break carrying the sealed key.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(io: std.Io, msg: []const u8) ![64]u8 {
    var kp = made: {
        break :made dep.sealedPair(io);
    };
    defer kp.deinit();
    return (try kp.expose().sign(msg, null)).toBytes();
}
