// A008: std's crypto captured from an optional, its hand wipe called through the capture: a finding.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = std.crypto;
pub fn wipe(key: *[32]u8) void {
    if (held) |crypto| crypto.secureZero(u8, key);
}
