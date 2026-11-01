// c1: the same input-bound loop after before.zig: what the run kept while before.zig's budget ran
// out is no answer here, so it is flagged or left undecided, never clean
const std = @import("std");
pub fn g(io: std.Io, r: *std.Io.Reader, out: *u8) !void {
    _ = io;
    var memory: [16]u8 = @splat(0);
    var s: []u8 = memory[0..];
    const n: usize = try r.takeInt(u32, .little);
    s.len = n;
    var i: usize = 0;
    while (i < s.len) : (i += 1) out.* +%= 1;
}
