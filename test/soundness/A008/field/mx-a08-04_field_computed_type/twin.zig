// matrix A008: the same field sealed in aegis's Secret.
const std = @import("std");
const aegis = @import("aegis");
const Ed25519 = std.crypto.sign.Ed25519;
pub const Signer = struct {
    key: aegis.Secret(@field(Ed25519, "Key" ++ "Pair")),
    uses: u32,
};
