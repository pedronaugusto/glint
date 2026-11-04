// The same key sealed, wiped by aegis's Secret.
const std = @import("std");
const aegis = @import("aegis");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn forget(kp: *aegis.Secret(Ed25519.KeyPair)) void {
    kp.deinit();
}
