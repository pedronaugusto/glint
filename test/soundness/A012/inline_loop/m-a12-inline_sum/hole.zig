// matrix A012 inline_loop: an inline for adds input read per type into the size
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: usize = 0;
    inline for (.{ u16, u32 }) |T| n += try r.takeInt(T, .little);
    return gpa.alloc(u8, n);
}
