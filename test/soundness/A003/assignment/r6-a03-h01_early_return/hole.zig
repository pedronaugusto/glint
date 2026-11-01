// review 6: a03/h01_early_return.zig
const std = @import("std");
// Leaks on the early return.
pub fn f(dir: std.Io.Dir, io: std.Io, c: bool) !void {
    const file = try dir.openFile(io, "a", .{});
    if (c) return;
    file.close(io);
}
