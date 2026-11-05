// A borrowed secret key's bytes read by value through a byte view: the array returned is a copy never wiped.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn export_(kp: *const Ed25519.KeyPair) [64]u8 {
    return std.mem.asBytes(&kp.secret_key).*;
}
