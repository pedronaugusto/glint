const std = @import("std");

pub fn syncFile(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
}

pub fn syncAgain(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
}

pub const lint_rules = .{
    .version = 1,
    .replaces = .{.{ .std = std.Io.File.sync, .with = syncFile, .why = "durability belongs to syncFile" }},
    .door = .{syncAgain},
};
