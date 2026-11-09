const std = @import("std");

pub fn syncFile(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
}
