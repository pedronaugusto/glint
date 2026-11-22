// A008: a scheme chosen by an if, its key type held plainly by a field: a finding.
const aegis = @import("aegis");
const std = @import("std");
const wide = false;
const Scheme = if (wide) std.crypto.sign.mldsa.MLDSA65 else std.crypto.sign.Ed25519;
pub const Signer = struct { key: Scheme.SecretKey };
