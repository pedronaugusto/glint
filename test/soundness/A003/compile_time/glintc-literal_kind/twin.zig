// glint-c: A003 compile_time: the same acquisition behind std.meta.hasMethod, which no anonymous literal passes (it declares nothing): never compiled for this binding, so no owner is made
const std = @import("std");
const w = @import("tw.zig");
fn open(dir: std.Io.Dir, io: std.Io) !std.Io.File {
    return dir.openFile(io, "a", .{});
}
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    try w.run(.{ .make = &open }, dir, io);
}
