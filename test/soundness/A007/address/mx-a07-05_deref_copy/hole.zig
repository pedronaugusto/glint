// matrix A007: a borrowed lock copied by `.*` into a variable: the copy is a second lock, held here.
const std = @import("std");
pub fn count(shared: *std.Io.Mutex, io: std.Io, n: *u32) void {
    var copy = shared.*;
    copy.lockUncancelable(io);
    defer copy.unlock(io);
    n.* += 1;
}
