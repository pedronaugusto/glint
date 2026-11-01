// matrix A008: the same @call making the sealed key.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(io: std.Io, msg: []const u8) ![64]u8 {
    var kp = @call(.auto, dep.sealedPair, .{io});
    defer kp.deinit();
    return (try kp.expose().sign(msg, null)).toBytes();
}
