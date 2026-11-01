// review 6: a03/h13_callee_closes_struct.zig
const std = @import("std");
const Box = struct { f: std.Io.File };
// The callee closes the copy put in a literal.
fn shut(f: std.Io.File, io: std.Io) void {
    const b: Box = .{ .f = f };
    b.f.close(io);
}
pub fn g(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    defer file.close(io);
    shut(file, io);
}
