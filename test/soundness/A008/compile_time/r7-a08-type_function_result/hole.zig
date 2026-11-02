// review 7 A008: a parameter holding std's secret key by value, its type given by std.meta.Child of a pointer to it: read as known only as the program compiles, and cleared.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn seedOf(k: std.meta.Child(*const Ed25519.SecretKey)) [32]u8 {
    return k.seed();
}
