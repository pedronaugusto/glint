// c1: the same tuple-sized allocation after before.zig: what the run kept while before.zig's
// budget ran out is no answer here, so it is flagged or left undecided, never clean
const std = @import("std");
pub fn g(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const t = .{ @as(u32, 8), try r.takeInt(u32, .little) };
    return gpa.alloc(u8, t[1]);
}
