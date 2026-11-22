// A007: std's Io the result of a labeled block, its lock reached through it: a finding.
const aegis = @import("aegis");
const std = @import("std");
const io = blk: {
    break :blk std.Io;
};
pub fn make() io.Mutex {
    return .init;
}
