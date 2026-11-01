// matrix A007: an optional lock a dependency gives, captured by value and held in a variable.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io, wanted: bool, n: *u32) void {
    if (dep.maybe(wanted)) |lock| {
        var own = lock;
        own.lockUncancelable(io);
        defer own.unlock(io);
        n.* += 1;
    }
}
