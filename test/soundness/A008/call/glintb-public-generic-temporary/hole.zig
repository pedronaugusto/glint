// glint-b A008: a key pair made in place and handed by value to the dependency's generic.
const std = @import("std");
const dep = @import("dep.zig");
pub fn size(io: std.Io) usize {
    return dep.sizeOf(std.crypto.sign.Ed25519.KeyPair.generate(io));
}
