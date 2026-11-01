// matrix A007: a variable given a lock a dependency makes holds raw synchronization; nothing in this file names the lock's type.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io, n: *u32) void {
    var lock = dep.make();
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    n.* += 1;
}
