// matrix A008: a borrowed key pair copied by `.*`: the copy holds the secret by value, never wiped.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn sign(kp: *const Ed25519.KeyPair, msg: []const u8) ![64]u8 {
    const copy = kp.*;
    return (try copy.sign(msg, null)).toBytes();
}
