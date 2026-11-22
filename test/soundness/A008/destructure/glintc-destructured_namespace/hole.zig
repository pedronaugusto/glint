// A008: std's timing_safe named by a destructure, its comparison called through it: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn same(a: [32]u8, b: [32]u8) bool {
    const safe, const mem = .{ std.crypto.timing_safe, std.mem };
    _ = mem;
    return safe.eql([32]u8, a, b);
}
