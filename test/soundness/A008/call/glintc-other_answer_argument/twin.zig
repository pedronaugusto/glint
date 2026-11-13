// A008: the key itself the answer's argument (8d).
const aegis = @import("aegis");
const std = @import("std");
pub const Held = aegis.Secret(std.crypto.sign.Ed25519.SecretKey);
