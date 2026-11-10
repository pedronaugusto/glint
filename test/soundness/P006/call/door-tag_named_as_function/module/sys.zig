const std = @import("std");

const Reached = enum { flushed, written };

fn flushed(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
}

fn report(reached: Reached) void {
    std.debug.assert(reached == .flushed);
}

pub fn flush(file: std.Io.File, io: std.Io) !void {
    try flushed(file, io);
    report(.flushed);
}
