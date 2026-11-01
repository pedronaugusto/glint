const std = @import("std");
const aegis = @import("aegis");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn pair(io: std.Io) struct { Ed25519.KeyPair, u32 } {
    return .{ .generate(io), 1 };
}
pub fn sealedPairTuple(io: std.Io) struct { aegis.Secret(Ed25519.KeyPair), u32 } {
    return .{ .init(.generate(io)), 1 };
}
