const std = @import("std");
pub fn flush(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
}
