// review 7 A008: the same type function giving the public key.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn bytesOf(k: std.meta.Child(*const Ed25519.PublicKey)) [32]u8 {
    return k.toBytes();
}
