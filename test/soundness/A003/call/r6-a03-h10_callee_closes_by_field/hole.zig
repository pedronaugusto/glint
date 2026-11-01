// review 6: a03/h10_callee_closes_by_field.zig
const std = @import("std");
// The callee closes its copy through @field of the type: with the deferred close, the file is closed twice.
fn shut(f: std.Io.File, io: std.Io) void {
    @field(std.Io.File, "close")(f, io);
}
pub fn g(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    defer file.close(io);
    shut(file, io);
}
