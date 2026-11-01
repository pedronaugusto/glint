// matrix A008: std's blinded Ed25519 key pair held by value: secret material under a name other than SecretKey or KeyPair.
const std = @import("std");
const aegis = @import("aegis");
const BlindKeyPair = std.crypto.sign.Ed25519.key_blinding.BlindKeyPair;
pub fn sign(kp: *const aegis.Secret(std.crypto.sign.Ed25519.KeyPair), seed: [32]u8, msg: []const u8) ![64]u8 {
    const blind = try BlindKeyPair.init(kp.expose().*, seed, "ctx");
    return (try blind.sign(msg, null)).toBytes();
}
