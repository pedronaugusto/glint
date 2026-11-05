// A008 (review 7 sweep): a secret key embedded by value from a ZON file: @import of a .zon is a value, not a namespace.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const key: Ed25519.SecretKey = @import("key.zon");
pub fn public() [32]u8 {
    return key.publicKeyBytes();
}
