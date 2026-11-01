// matrix A008: a borrowed secret key wiped by hand with @memset, a store the optimizer may drop.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn forget(kp: *Ed25519.KeyPair) void {
    @memset(&kp.secret_key.bytes, 0);
}
