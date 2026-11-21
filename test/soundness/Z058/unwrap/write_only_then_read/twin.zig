// Z058 twin: opened `.mode = .read_write`, so the read is the handle's to make.
const std = @import("std");
pub fn first(dir: std.Io.Dir, io: std.Io, buffer: []u8) !usize {
    const file = dir.openFile(io, "log", .{ .mode = .read_write }) catch |err| return err;
    defer file.close(io);
    return file.readPositional(io, &.{buffer}, 0);
}
