// matrix A007: the same borrow kept a pointer: the lock stays where it is held.
const std = @import("std");
pub fn count(shared: *std.Io.Mutex, io: std.Io, n: *u32) void {
    const held = shared;
    held.lockUncancelable(io);
    defer held.unlock(io);
    n.* += 1;
}
