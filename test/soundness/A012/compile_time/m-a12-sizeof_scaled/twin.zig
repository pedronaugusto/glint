// matrix A012 compile_time: the size is the input's type's size, known at compile time
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = try r.takeInt(u32, .little);
    return gpa.alloc(u8, @sizeOf(@TypeOf(n)));
}
