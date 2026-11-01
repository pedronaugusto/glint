// matrix A007: a variable typed @TypeOf a borrowed lock's value holds a lock of its own.
const std = @import("std");
pub fn count(shared: *const std.Io.Mutex, io: std.Io, n: *u32) void {
    var own: @TypeOf(shared.*) = .init;
    own.lockUncancelable(io);
    defer own.unlock(io);
    n.* += 1;
}
