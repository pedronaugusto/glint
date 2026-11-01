// matrix A008: the same tuple holding the sealed key.
const std = @import("std");
const dep = @import("dep.zig");
pub fn sign(io: std.Io, msg: []const u8) ![64]u8 {
    var held = .{ dep.sealedPair(io), @as(u32, 0) };
    defer held[0].deinit();
    return (try held[0].expose().sign(msg, null)).toBytes();
}
