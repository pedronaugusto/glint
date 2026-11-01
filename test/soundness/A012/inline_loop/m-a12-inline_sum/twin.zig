// matrix A012 inline_loop: the inline for adds each type's size, the input read beside it
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: usize = 0;
    inline for (.{ u16, u32 }) |T| {
        _ = try r.takeInt(T, .little);
        n += @sizeOf(T);
    }
    return gpa.alloc(u8, n);
}
