// matrix A008: the same destructure taking the key sealed.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(io: std.Io, msg: []const u8) ![64]u8 {
    var kp, const uses = dep.sealedPairTuple(io);
    _ = uses;
    defer kp.deinit();
    return (try kp.expose().sign(msg, null)).toBytes();
}
