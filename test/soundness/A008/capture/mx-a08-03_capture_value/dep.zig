const std = @import("std");
const aegis = @import("aegis");
const Ed25519 = std.crypto.sign.Ed25519;
var shared: aegis.Secret(Ed25519.KeyPair) = undefined;
pub fn maybePair(io: std.Io, wanted: bool) ?Ed25519.KeyPair {
    return if (wanted) .generate(io) else null;
}
pub fn maybeShared(wanted: bool) ?*const aegis.Secret(Ed25519.KeyPair) {
    return if (wanted) &shared else null;
}
