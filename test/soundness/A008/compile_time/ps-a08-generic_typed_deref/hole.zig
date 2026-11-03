// pre-sweep A008: a generic bound to std's SecretKey, naming it only behind a pointer (read as holding none), copies what the pointer points at by value.
const std = @import("std");
const dep = @import("dep.zig");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn check(kp: *const Ed25519.KeyPair) u32 {
    return dep.sum(Ed25519.SecretKey, &kp.secret_key);
}
