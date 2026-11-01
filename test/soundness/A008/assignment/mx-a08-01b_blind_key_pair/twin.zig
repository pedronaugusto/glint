// matrix A008: the same blinded key pair sealed in aegis's Secret.
const std = @import("std");
const aegis = @import("aegis");
const BlindKeyPair = std.crypto.sign.Ed25519.key_blinding.BlindKeyPair;
pub fn sign(kp: *const aegis.Secret(std.crypto.sign.Ed25519.KeyPair), seed: [32]u8, msg: []const u8) ![64]u8 {
    var blind = aegis.Secret(BlindKeyPair).init(try BlindKeyPair.init(kp.expose().*, seed, "ctx"));
    defer blind.deinit();
    return (try blind.expose().sign(msg, null)).toBytes();
}
