const std = @import("std");

var last: ?*const fn (std.Io.File, std.Io) anyerror!void = null;

fn raw(file: std.Io.File, io: std.Io) anyerror!void {
    try file.sync(io);
}

fn retrying(comptime call: anytype, args: anytype) !void {
    last = call;
    return @call(.auto, call, args);
}

pub fn flush(file: std.Io.File, io: std.Io) !void {
    try retrying(raw, .{ file, io });
}

pub fn again(file: std.Io.File, io: std.Io) !void {
    if (last) |call| try call(file, io);
}
