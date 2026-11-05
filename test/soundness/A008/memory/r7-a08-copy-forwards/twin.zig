// The public half copied the same way.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn stash(kp: *const Ed25519.KeyPair, out: []u8) void {
    std.mem.copyForwards(u8, out, &kp.public_key.bytes);
}
