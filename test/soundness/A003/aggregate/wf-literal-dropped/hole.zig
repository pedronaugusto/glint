// warp-fast: the file moved into a local literal that is never handed on leaks with it.
const std = @import("std");
const Pair = struct { file: std.Io.File, n: u32 };
pub fn f(dir: std.Io.Dir, io: std.Io) !u32 {
    const file = try dir.openFile(io, "a", .{});
    const pair: Pair = .{ .file = file, .n = 1 };
    return pair.n;
}
