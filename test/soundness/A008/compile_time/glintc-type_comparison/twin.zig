// A008: a comparison of types names the key's type and holds no value of it (8d).
const aegis = @import("aegis");
const std = @import("std");
pub fn isEd25519(comptime T: type) bool {
    return T == std.crypto.sign.Ed25519.SecretKey;
}
