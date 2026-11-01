const std = @import("std");
pub fn Key() type {
    return std.crypto.sign.Ed25519.SecretKey;
}
