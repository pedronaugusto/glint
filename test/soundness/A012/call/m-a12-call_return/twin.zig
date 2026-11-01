// matrix A012 call: the helper limits the size it returns
const std = @import("std");
fn size(r: *std.Io.Reader) !u32 {
    const n = try r.takeInt(u32, .little);
    if (n > 4096) return error.TooLarge;
    return n;
}
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    return gpa.alloc(u8, try size(r));
}
