// A008: std's crypto an element of tuples joined by ++, its hand wipe called: a finding.
const aegis = @import("aegis");
const std = @import("std");
const both = .{std.mem} ++ .{std.crypto};
pub fn wipe(key: *[32]u8) void {
    both[1].secureZero(u8, key);
}
