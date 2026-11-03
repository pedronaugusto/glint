const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
// A dependency's record holding a secret key by value, and one holding a public key.
pub const Wallet = struct { key: Ed25519.SecretKey, label: u8 = 0 };
pub const Shown = struct { key: Ed25519.PublicKey, label: u8 = 0 };
