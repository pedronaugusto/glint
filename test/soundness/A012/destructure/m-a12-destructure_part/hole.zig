// matrix A012 destructure: the part destructured from input sizes the allocation
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n, const k = .{ try r.takeInt(u32, .little), @as(u32, 1) };
    _ = k;
    return gpa.alloc(u8, n);
}
