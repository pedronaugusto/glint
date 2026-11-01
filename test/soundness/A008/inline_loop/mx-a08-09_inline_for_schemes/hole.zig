// matrix A008: an inline for over signature schemes: each unrolled constant holds a scheme's key pair by value.
const std = @import("std");
pub fn publicKeys(io: std.Io, out: [][]const u8) void {
    inline for (.{ std.crypto.sign.Ed25519, std.crypto.sign.ecdsa.EcdsaP256Sha256 }, 0..) |Scheme, i| {
        const kp = Scheme.KeyPair.generate(io);
        _ = kp;
        out[i] = "";
    }
}
