// c1: the same discarded acquisition after before.zig: what the run kept while before.zig's
// budget ran out is no answer here, so the leak is flagged or left undecided, never clean
const std = @import("std");
pub fn g(dir: std.Io.Dir, io: std.Io) !void {
    _ = try dir.openFile(io, "b", .{});
}
