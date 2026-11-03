// pre-sweep A008: a borrowed secret key handed by address to a dependency's generic that copies what the pointer points at (`p.*`) by value: the binding makes the generic hold std's secret material, and nothing judges it.
const std = @import("std");
const dep = @import("dep.zig");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn keep(kp: *const Ed25519.KeyPair) void {
    dep.remember(&kp.secret_key);
}
