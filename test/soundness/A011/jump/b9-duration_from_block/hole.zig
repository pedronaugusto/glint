// A011: std's Duration the result of a labeled block, its raw nanoseconds read: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(d: std.Io.Duration) i96 {
    const held = blk: {
        break :blk d;
    };
    return held.nanoseconds;
}
