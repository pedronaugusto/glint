// matrix A008: the same inline for, each key pair sealed in aegis's Secret.
const std = @import("std");
const aegis = @import("aegis");
pub fn publicKeys(io: std.Io, out: [][]const u8) void {
    inline for (.{ std.crypto.sign.Ed25519, std.crypto.sign.ecdsa.EcdsaP256Sha256 }, 0..) |Scheme, i| {
        var kp = aegis.Secret(Scheme.KeyPair).init(.generate(io));
        defer kp.deinit();
        out[i] = "";
    }
}
