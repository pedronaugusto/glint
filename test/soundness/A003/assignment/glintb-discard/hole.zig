// glint-b: A003 assignment (discard): an acquisition discarded with `_ =` is never released
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    _ = try dir.openFile(io, "a", .{});
}
