// A008: a field holding std's secret key as plain bytes.
const aegis = @import("aegis");
const std = @import("std");
pub const Signer = struct { key: std.crypto.sign.Ed25519.SecretKey };
