// review 6: a03/h11_callee_closes_via_ptr.zig
const std = @import("std");
// The callee closes through a function pointer it is handed.
fn shut(f: std.Io.File, io: std.Io, how: *const fn (std.Io.File, std.Io) void) void {
    how(f, io);
}
fn closer(f: std.Io.File, io: std.Io) void {
    f.close(io);
}
pub fn g(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    defer file.close(io);
    shut(file, io, closer);
}
