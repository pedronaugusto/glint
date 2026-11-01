// matrix: input put into a tuple literal, its element then sizes the allocation
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const t = .{ @as(u32, 8), try r.takeInt(u32, .little) };
    return gpa.alloc(u8, t[1]);
}
