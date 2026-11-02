// review 7 A008: a parameter of a tuple type written in place holds std's secret key by value: a tuple's fields are no declarations, and a record no type function made is read as holding none.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn seedOf(k: struct { Ed25519.SecretKey, u8 }) [32]u8 {
    return k[0].seed();
}
