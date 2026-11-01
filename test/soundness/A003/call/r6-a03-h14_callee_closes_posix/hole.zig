// review 6: a03/h14_callee_closes_posix.zig
const std = @import("std");
// The callee closes the handle through a std call named otherwise.
fn shut(f: std.Io.File) void {
    _ = std.posix.system.close(f.handle);
}
pub fn g(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    defer file.close(io);
    shut(file);
}
