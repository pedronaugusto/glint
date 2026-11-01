// review 6: a03/h10b_callee_closes.zig
const std = @import("std");
fn shut(f: std.Io.File, io: std.Io) void {
    f.close(io);
}
pub fn g(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    defer file.close(io);
    shut(file, io);
}
