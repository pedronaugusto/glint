// A008: a comparison of types, one operand a comptime parameter's member: Zig compares a type
// only with a type, so it holds no value of either (cloak's keeps_seed in its Pure(K), 8g).
const aegis = @import("aegis");
const std = @import("std");
fn Kind(comptime K: type) type {
    return struct {
        pub const same = K.SecretKey != std.crypto.sign.Ed25519.SecretKey;
    };
}
pub const ed = Kind(std.crypto.sign.Ed25519).same;
