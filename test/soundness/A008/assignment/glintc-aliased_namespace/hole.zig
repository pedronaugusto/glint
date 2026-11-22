// A008: std's crypto held by a const, its hand wipe called through it: a finding.
const aegis = @import("aegis");
const std = @import("std");
const crypto = std.crypto;
pub fn wipe(key: *[32]u8) void {
    crypto.secureZero(u8, key);
}
