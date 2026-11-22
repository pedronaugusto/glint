// A008: std's timing_safe the result of a labeled block, its comparison called: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn same(a: [32]u8, b: [32]u8) bool {
    const safe = blk: {
        break :blk std.crypto.timing_safe;
    };
    return safe.eql([32]u8, a, b);
}
