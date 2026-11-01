// matrix A007: the same capture of a borrow of the dependency's lock: nothing held here.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io, wanted: bool, n: *u32) void {
    if (dep.maybeShared(wanted)) |lock| {
        lock.lockUncancelable(io);
        defer lock.unlock(io);
        n.* += 1;
    }
}
