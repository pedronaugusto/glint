const std = @import("std");
const aegis = @import("aegis");
const Ed25519 = std.crypto.sign.Ed25519;
// A dependency that hands out a key pair by value, and one that hands it out sealed.
pub fn newPair(io: std.Io) Ed25519.KeyPair {
    return .generate(io);
}
pub fn sealedPair(io: std.Io) aegis.Secret(Ed25519.KeyPair) {
    return .init(.generate(io));
}
pub fn tryPair(seed: [32]u8) !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(seed);
}
pub fn trySealed(seed: [32]u8) !aegis.Secret(Ed25519.KeyPair) {
    return .init(try Ed25519.KeyPair.generateDeterministic(seed));
}
