// A008: the key held through the entry's own answer: Secret(T) is the answer, no site (8d).
const aegis = @import("aegis");
const std = @import("std");
pub const Signer = struct { key: aegis.Secret(std.crypto.sign.Ed25519.SecretKey) };
