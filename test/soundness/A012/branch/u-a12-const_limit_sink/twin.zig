// A012: a number from input checked against the program's `const` limit on every path, then the
// size the allocation takes: held where the sink reads it (Proof.counts; at a call only Range's
// half is read, see call/u-a12-const_limit_kept).
const std = @import("std");
const max = 4096;
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = try r.takeInt(u32, .little);
    if (n > max) return error.TooBig;
    return gpa.alloc(u8, n);
}
