// glint-c: A003 compile_time: a generic acquiring through a function an anonymous literal gives (`.{ .make = &open }`), behind a test of its type info that a literal passes (an anonymous struct): the binding makes an owner
const std = @import("std");
const w = @import("w.zig");
fn open(dir: std.Io.Dir, io: std.Io) !std.Io.File {
    return dir.openFile(io, "a", .{});
}
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    try w.run(.{ .make = &open }, dir, io);
}
