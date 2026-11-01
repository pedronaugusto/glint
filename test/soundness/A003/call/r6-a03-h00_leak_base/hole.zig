// review 6: a03/h00_leak_base.zig
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    _ = file;
}
