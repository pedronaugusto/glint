// glint-b A008: the same generic bound to the sealed key pair.
const std = @import("std");
const aegis = @import("aegis");
const dep = @import("dep.zig");
pub fn size(io: std.Io) usize {
    return dep.made(aegis.Secret(std.crypto.sign.Ed25519.KeyPair), io);
}
