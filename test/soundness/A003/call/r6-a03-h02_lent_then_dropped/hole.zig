// review 6: a03/h02_lent_then_dropped.zig
const std = @import("std");
fn use(lent: std.Io.File) void {
    _ = lent;
}
// Handed to a call that does not release it, then never released.
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    use(file);
}
