// matrix A007: @call makes the dependency's lock: the variable holds it as a plain call's result would.
const std = @import("std");
const dep = @import("dep.zig");
pub fn count(io: std.Io, n: *u32) void {
    var lock = @call(.auto, dep.make, .{});
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    n.* += 1;
}
