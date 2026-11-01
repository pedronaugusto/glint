// matrix A012 operator: input masked to twelve bits, plus a header's size
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = try r.takeInt(u32, .little);
    return gpa.alloc(u8, (n & 0xfff) + 8);
}
