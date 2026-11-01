// matrix A008: a secret key's length read from its type: a compile-time constant, no key held.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn keyLength() usize {
    return Ed25519.SecretKey.encoded_length;
}
