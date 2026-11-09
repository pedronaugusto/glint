const std = @import("std");
const sys = @import("sys.zig");
pub const flush = sys.flush;

pub fn syncFile(file: std.Io.File, io: std.Io) !void {
    try sys.flush(file, io);
}

pub const lint_rules = .{
    .version = 1,
    .replaces = .{.{ .std = std.Io.File.sync, .with = syncFile, .why = "durability belongs to syncFile" }},
};
