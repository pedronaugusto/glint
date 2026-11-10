const std = @import("std");

pub const Hook = struct { run: *const fn (std.Io.File, std.Io) anyerror!void };

fn raw(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
}

fn retrying(comptime call: anytype, args: anytype) !void {
    return @call(.auto, call, args);
}

pub fn flush(file: std.Io.File, io: std.Io) !void {
    try retrying(raw, .{ file, io });
}

pub fn hook() Hook {
    return .{ .run = raw };
}
