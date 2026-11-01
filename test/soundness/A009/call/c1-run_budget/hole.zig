// c1: the same read after before.zig: what the run kept while before.zig's budget ran out is
// no answer here, so the index is flagged or left undecided, never clean
const std = @import("std");
pub fn g(r: *std.Io.Reader, table: *const [16]u8) !u8 {
    const n = try r.takeByte();
    return table[n];
}
