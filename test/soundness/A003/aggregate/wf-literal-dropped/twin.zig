// warp-fast: the local literal holding the file is handed to the caller.
const std = @import("std");
const Pair = struct { file: std.Io.File, n: u32 };
pub fn f(dir: std.Io.Dir, io: std.Io) !Pair {
    const file = try dir.openFile(io, "a", .{});
    const pair: Pair = .{ .file = file, .n = 1 };
    return pair;
}
