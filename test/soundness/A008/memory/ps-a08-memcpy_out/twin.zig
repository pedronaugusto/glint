// pre-sweep A008: the public half copied the same way: no secret material.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn stash(kp: *const Ed25519.KeyPair, out: *[32]u8) void {
    @memcpy(out, &kp.public_key.bytes);
}
