// matrix A008: the same @TypeOf of the borrow itself: a pointer.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn sign(kp: *const Ed25519.KeyPair, msg: []const u8) ![64]u8 {
    const held: @TypeOf(kp) = kp;
    return (try held.sign(msg, null)).toBytes();
}
