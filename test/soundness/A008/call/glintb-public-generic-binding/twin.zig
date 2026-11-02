// glint-b A008: the same generic bound to a type that keeps the key pair sealed.
const std = @import("std");
const aegis = @import("aegis");
const dep = @import("dep.zig");
const KeyPair = std.crypto.sign.Ed25519.KeyPair;
const Sealed = struct {
    pair: aegis.Secret(KeyPair),
    pub fn generate(io: std.Io) Sealed {
        return .{ .pair = .init(KeyPair.generate(io)) };
    }
};
pub fn size(io: std.Io) usize {
    return dep.made(Sealed, io);
}
