const std = @import("std");

pub fn probe(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
}
