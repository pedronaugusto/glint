// A008 (review 7 sweep): the same ZON imported as plain bytes and sealed in aegis's Secret where it is used.
const std = @import("std");
const aegis = @import("aegis");
const Ed25519 = std.crypto.sign.Ed25519;
const Raw = struct { bytes: [64]u8 };
const raw: Raw = @import("key.zon");
pub fn public() [32]u8 {
    var key: aegis.Secret(Ed25519.SecretKey) = .init(.{ .bytes = raw.bytes });
    defer key.deinit();
    return key.expose().publicKeyBytes();
}
