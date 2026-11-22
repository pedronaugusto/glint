// A008: a signature scheme an element of a tuple, its key type handed to the answer: none.
const aegis = @import("aegis");
const std = @import("std");
const schemes = .{std.crypto.sign.Ed25519};
pub const Signer = struct { key: aegis.Secret(schemes[0].SecretKey) };
