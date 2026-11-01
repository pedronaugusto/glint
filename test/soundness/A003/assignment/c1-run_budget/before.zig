// c1: a program's other file, read first: it spends this file's fact budget inside the answers
// the run keeps for every file (std's Dir.openFile and what it acquires)
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    _ = try dir.openFile(io, "a", .{});
}
