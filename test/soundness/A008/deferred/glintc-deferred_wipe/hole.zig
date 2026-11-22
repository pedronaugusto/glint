// A008: a hand wipe deferred to the scope's end, through an alias: a finding.
const aegis = @import("aegis");
const std = @import("std");
const crypto = std.crypto;
pub fn use(seed: [32]u8) u8 {
    var key = seed;
    defer crypto.secureZero(u8, &key);
    return key[0];
}
