// matrix A007: the same @TypeOf of the borrow itself: a pointer, holding nothing.
const std = @import("std");
pub fn count(shared: *std.Io.Mutex, io: std.Io, n: *u32) void {
    const held: @TypeOf(shared) = shared;
    held.lockUncancelable(io);
    defer held.unlock(io);
    n.* += 1;
}
