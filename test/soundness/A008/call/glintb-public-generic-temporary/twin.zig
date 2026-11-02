// glint-b A008: the sealed key pair's address handed instead.
const std = @import("std");
const aegis = @import("aegis");
const dep = @import("dep.zig");
pub fn size(io: std.Io) usize {
    var kp: aegis.Secret(std.crypto.sign.Ed25519.KeyPair) = .init(.generate(io));
    defer kp.deinit();
    return dep.sizeOf(&kp);
}
