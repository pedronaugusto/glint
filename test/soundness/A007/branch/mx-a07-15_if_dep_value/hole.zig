// matrix A007: an `if` chooses which of the dependency's locks a variable holds a copy of.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io, fresh: bool, n: *u32) void {
    var lock = if (fresh) dep.make() else dep.global;
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    n.* += 1;
}
