// matrix A007: a destructure takes a lock out of a dependency's tuple into a variable.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io) u32 {
    var lock, const n = dep.pair();
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    return n;
}
