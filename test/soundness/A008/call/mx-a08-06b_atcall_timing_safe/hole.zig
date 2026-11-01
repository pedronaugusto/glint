// matrix A008: std's timing-safe comparison called through @call: a hand comparison.
const std = @import("std");
pub fn same(a: [32]u8, b: [32]u8) bool {
    return @call(.auto, std.crypto.timing_safe.eql, .{ [32]u8, a, b });
}
