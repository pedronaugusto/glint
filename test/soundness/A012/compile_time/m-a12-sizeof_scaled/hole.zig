// matrix A012 compile_time: an input count scaled by a type's size
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = try r.takeInt(u32, .little);
    return gpa.alloc(u8, n * @sizeOf(u64));
}
