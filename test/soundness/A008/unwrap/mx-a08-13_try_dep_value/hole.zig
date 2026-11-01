// matrix A008: `try` unwraps the dependency's key pair into a constant.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(seed: [32]u8, msg: []const u8) ![64]u8 {
    const kp = try dep.tryPair(seed);
    return (try kp.sign(msg, null)).toBytes();
}
