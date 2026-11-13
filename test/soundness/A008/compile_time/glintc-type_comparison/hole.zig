// A008: std's key pair generated into a local, its secret key plain on the stack.
const aegis = @import("aegis");
const std = @import("std");
pub fn public(io: std.Io) [32]u8 {
    const pair = std.crypto.sign.Ed25519.KeyPair.generate(io);
    return pair.public_key.toBytes();
}
