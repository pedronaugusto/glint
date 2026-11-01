// matrix A008: the same `try` unwrapping the sealed key.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(seed: [32]u8, msg: []const u8) ![64]u8 {
    var kp = try dep.trySealed(seed);
    defer kp.deinit();
    return (try kp.expose().sign(msg, null)).toBytes();
}
