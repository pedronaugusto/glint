// matrix A008: a constant typed @TypeOf a borrowed key pair's value holds a copy by value.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn sign(kp: *const Ed25519.KeyPair, msg: []const u8) ![64]u8 {
    const copy: @TypeOf(kp.*) = kp.*;
    return (try copy.sign(msg, null)).toBytes();
}
