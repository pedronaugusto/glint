const std = @import("std");

fn raw(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
}

fn once(comptime call: anytype, args: anytype) !void {
    return @call(.auto, call, args);
}

fn retrying(comptime call: anytype, args: anytype) !void {
    try once(call, args);
}

pub fn flush(file: std.Io.File, io: std.Io) !void {
    try retrying(raw, .{ file, io });
}
