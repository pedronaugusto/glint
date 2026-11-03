// pre-sweep A008: the public half read the same way.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn export_(kp: *const Ed25519.KeyPair) [32]u8 {
    return std.mem.asBytes(&kp.public_key).*;
}
