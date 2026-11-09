const std = @import("std");

var global_file: std.Io.File = undefined;
var global_io: std.Io = undefined;

export fn flushForC() void {
    global_file.sync(global_io) catch {};
}

pub fn syncFile(file: std.Io.File, io: std.Io) !void {
    global_file = file;
    global_io = io;
    flushForC();
}

pub const lint_rules = .{
    .version = 1,
    .replaces = .{.{ .std = std.Io.File.sync, .with = syncFile, .why = "durability belongs to syncFile" }},
};
