// matrix A008: the same capture of a borrow of the sealed key.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(wanted: bool, msg: []const u8) !?[64]u8 {
    if (dep.maybeShared(wanted)) |kp| return (try kp.expose().sign(msg, null)).toBytes();
    return null;
}
