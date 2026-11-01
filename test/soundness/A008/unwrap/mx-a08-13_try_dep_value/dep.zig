const std = @import("std");
const aegis = @import("aegis");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn tryPair(seed: [32]u8) !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(seed);
}
pub fn trySealed(seed: [32]u8) !aegis.Secret(Ed25519.KeyPair) {
    return .init(try Ed25519.KeyPair.generateDeterministic(seed));
}
