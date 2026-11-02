// glint-b A008: the same box made with the sealed key pair.
const std = @import("std");
const aegis = @import("aegis");
const dep = @import("dep.zig");
pub fn keep(io: std.Io) dep.Box(aegis.Secret(std.crypto.sign.Ed25519.KeyPair)) {
    return .{ .value = .init(.generate(io)) };
}
