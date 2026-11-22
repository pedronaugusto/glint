// A008: std's crypto an unrolled loop's capture, its hand wipe called through it: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn wipe(key: *[32]u8) void {
    inline for (.{std.crypto}) |crypto| crypto.secureZero(u8, key);
}
