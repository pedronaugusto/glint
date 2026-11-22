// A008: the key type converted to a type by @as, handed to the answer: none.
const aegis = @import("aegis");
const std = @import("std");
pub const Signer = struct { key: aegis.Secret(@as(type, std.crypto.sign.Ed25519.SecretKey)) };
