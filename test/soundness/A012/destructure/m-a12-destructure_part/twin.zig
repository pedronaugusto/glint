// matrix A012 destructure: the part that sizes the allocation is a constant beside the input
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n, const k = .{ @as(u32, 64), try r.takeInt(u32, .little) };
    _ = k;
    return gpa.alloc(u8, n);
}
