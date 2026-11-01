// matrix A007: `try` unwraps the dependency's lock into a variable.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io, n: *u32) !void {
    var lock = try dep.tryMake(true);
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    n.* += 1;
}
