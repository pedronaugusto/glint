const std = @import("std");

pub const Hooks = struct { run: *const fn (std.Io.File, std.Io) anyerror!void };

var kept: Hooks = undefined;

fn raw(file: std.Io.File, io: std.Io) anyerror!void {
    try file.sync(io);
}

fn keep(call: *const fn (std.Io.File, std.Io) anyerror!void) void {
    kept = .{ .run = call };
}

pub fn flush(file: std.Io.File, io: std.Io) !void {
    keep(raw);
    try kept.run(file, io);
}

pub fn hooks() Hooks {
    return kept;
}
