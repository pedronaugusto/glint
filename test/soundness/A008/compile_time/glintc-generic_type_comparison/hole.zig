// A008: a type function's field holding the bound key type plainly.
const aegis = @import("aegis");
const std = @import("std");
fn Held(comptime K: type) type {
    return struct { key: K.SecretKey };
}
pub const Ed = Held(std.crypto.sign.Ed25519);
