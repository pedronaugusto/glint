// A008: a field whose type is a choice of the seed or the key, held plainly.
const aegis = @import("aegis");
const std = @import("std");
const seeded = false;
pub const Held = struct { key: if (seeded) [32]u8 else std.crypto.sign.Ed25519.SecretKey };
