// pre-sweep A008: a borrowed key pair's secret bytes copied by @memcpy into a plain array the program keeps: the copy is never wiped.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn stash(kp: *const Ed25519.KeyPair, out: *[64]u8) void {
    @memcpy(out, &kp.secret_key.bytes);
}
