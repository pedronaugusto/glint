// review 7 A008: the same tuple holding the public key.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn bytesOf(k: struct { Ed25519.PublicKey, u8 }) [32]u8 {
    return k[0].toBytes();
}
