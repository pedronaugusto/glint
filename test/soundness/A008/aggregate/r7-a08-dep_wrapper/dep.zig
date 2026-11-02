const std = @import("std");
const aegis = @import("aegis");
const Ed25519 = std.crypto.sign.Ed25519;
// A dependency's record that holds a secret key by value, and one that holds it sealed.
pub const Wallet = struct { key: Ed25519.SecretKey, label: u8 };
pub const SealedWallet = struct { key: aegis.Secret(Ed25519.SecretKey), label: u8 };
pub fn open(io: std.Io) Wallet {
    return .{ .key = Ed25519.KeyPair.generate(io).secret_key, .label = 0 };
}
pub fn openSealed(io: std.Io) SealedWallet {
    return .{ .key = .init(Ed25519.KeyPair.generate(io).secret_key), .label = 0 };
}
