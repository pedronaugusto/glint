// A008: a signature scheme an element of a tuple, its key type held plainly by a field: a finding.
const aegis = @import("aegis");
const std = @import("std");
const schemes = .{std.crypto.sign.Ed25519};
pub const Signer = struct { key: schemes[0].SecretKey };
