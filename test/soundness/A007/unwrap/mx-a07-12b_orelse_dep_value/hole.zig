// matrix A007: `orelse` unwraps the dependency's optional lock into a variable.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io, wanted: bool, n: *u32) void {
    var lock = dep.maybe(wanted) orelse return;
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    n.* += 1;
}
