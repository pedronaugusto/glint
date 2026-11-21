// Z058: a file opened `.mode = .write_only`, its handle out of a `catch`, then read through it:
// the handle has no read access on any system.
const std = @import("std");
pub fn first(dir: std.Io.Dir, io: std.Io, buffer: []u8) !usize {
    const file = dir.openFile(io, "log", .{ .mode = .write_only }) catch |err| return err;
    defer file.close(io);
    return file.readPositional(io, &.{buffer}, 0);
}
