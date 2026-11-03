const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
// A dependency's array of one secret key, and of one public key.
pub const Keys = [1]Ed25519.SecretKey;
pub const Shown = [1]Ed25519.PublicKey;
