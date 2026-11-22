// A008: the key type converted to a type by @as, held plainly by a field: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub const Signer = struct { key: @as(type, std.crypto.sign.Ed25519.SecretKey) };
