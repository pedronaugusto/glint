// pre-sweep A008: the same generic given the public half.
const std = @import("std");
const dep = @import("dep.zig");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn keep(kp: *const Ed25519.KeyPair) void {
    dep.remember(&kp.public_key);
}
