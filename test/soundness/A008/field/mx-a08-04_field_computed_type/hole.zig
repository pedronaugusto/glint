// matrix A008: a field whose type @field names with a computed name is std's key pair, by value.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub const Signer = struct {
    key: @field(Ed25519, "Key" ++ "Pair"),
    uses: u32,
};
