// A008: a scheme chosen by an if, its key type handed to the answer: none.
const aegis = @import("aegis");
const std = @import("std");
const wide = false;
const Scheme = if (wide) std.crypto.sign.mldsa.MLDSA65 else std.crypto.sign.Ed25519;
pub const Signer = struct { key: aegis.Secret(Scheme.SecretKey) };
