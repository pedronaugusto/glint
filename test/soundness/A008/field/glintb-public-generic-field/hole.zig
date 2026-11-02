// glint-b A008: a dependency's public generic made with a key pair holds it by value in its field.
const std = @import("std");
const dep = @import("dep.zig");
pub fn keep(io: std.Io) dep.Box(std.crypto.sign.Ed25519.KeyPair) {
    return .{ .value = .generate(io) };
}
