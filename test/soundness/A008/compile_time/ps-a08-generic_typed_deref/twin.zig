// pre-sweep A008: the same generic bound to the public key.
const std = @import("std");
const dep = @import("dep.zig");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn check(kp: *const Ed25519.KeyPair) u32 {
    return dep.sum(Ed25519.PublicKey, &kp.public_key);
}
