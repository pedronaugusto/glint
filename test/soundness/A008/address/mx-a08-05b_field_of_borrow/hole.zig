// matrix A008: a borrowed key pair's secret key read out by value through its field.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn seedOf(kp: *const Ed25519.KeyPair) [32]u8 {
    const secret = kp.secret_key;
    return secret.seed();
}
