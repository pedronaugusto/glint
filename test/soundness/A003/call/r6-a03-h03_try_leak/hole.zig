// review 6: a03/h03_try_leak.zig
const std = @import("std");
fn step() !void {}
// Leaks when step fails.
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    try step();
    file.close(io);
}
