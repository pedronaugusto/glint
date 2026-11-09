const std = @import("std");
const part = @import("part.zig");

pub fn syncFile(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
}

pub const stray = part.probe;

pub const lint_rules = .{
    .version = 1,
    .replaces = .{.{ .std = std.Io.File.sync, .with = syncFile, .why = "durability belongs to syncFile" }},
};
