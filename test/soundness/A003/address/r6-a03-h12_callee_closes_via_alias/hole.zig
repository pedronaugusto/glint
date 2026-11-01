// review 6: a03/h12_callee_closes_via_alias.zig
const std = @import("std");
// The callee closes a local copy of its parameter.
fn shut(f: std.Io.File, io: std.Io) void {
    const g2 = f;
    g2.close(io);
}
pub fn g(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    defer file.close(io);
    shut(file, io);
}
