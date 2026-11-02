// glint-b A008: binding the dependency's generic to a key pair makes one held by value there.
const std = @import("std");
const dep = @import("dep.zig");
pub fn size(io: std.Io) usize {
    return dep.made(std.crypto.sign.Ed25519.KeyPair, io);
}
