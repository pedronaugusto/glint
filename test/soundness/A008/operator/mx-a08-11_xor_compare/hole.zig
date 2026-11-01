// matrix A008: a borrowed secret key compared with another by hand, xor and or over its bytes, outside Choice.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn same(a: *const Ed25519.SecretKey, b: *const Ed25519.SecretKey) bool {
    var diff: u8 = 0;
    for (a.bytes, b.bytes) |x, y| diff |= x ^ y;
    return diff == 0;
}
