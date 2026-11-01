// matrix A007: a labeled block's break carries the dependency's lock into a variable.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io, n: *u32) void {
    var lock = made: {
        break :made dep.make();
    };
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    n.* += 1;
}
