// c1: a program's other file, read first: it spends this file's fact budget inside the answers
// the run keeps for every file (what std's reader and the loop's calls can cancel)
const std = @import("std");
pub fn f(io: std.Io, r: *std.Io.Reader, out: *u8) !void {
    _ = io;
    var memory: [16]u8 = @splat(0);
    var s: []u8 = memory[0..];
    const n: usize = try r.takeInt(u32, .little);
    s.len = n;
    var i: usize = 0;
    while (i < s.len) : (i += 1) out.* +%= 1;
}
