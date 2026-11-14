// A008: the answer's argument is a choice of the seed or the key: the type handed to Secret
// either way, so the answer (cloak's ML-KEM private half, 8g).
const aegis = @import("aegis");
const std = @import("std");
const seeded = false;
pub const Held = struct { key: aegis.Secret(if (seeded) [32]u8 else std.crypto.sign.Ed25519.SecretKey) };
