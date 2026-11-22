// A008: std's crypto unwrapped from an optional by .?, its hand wipe called: a finding.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = std.crypto;
pub fn wipe(key: *[32]u8) void {
    held.?.secureZero(u8, key);
}
