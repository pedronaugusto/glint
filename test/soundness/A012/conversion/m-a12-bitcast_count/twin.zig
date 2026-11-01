// matrix A012 conversion: the reinterpreted count is limited first
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const bytes = try r.takeArray(4);
    const n: u32 = @bitCast(bytes.*);
    if (n > 4096) return error.TooLarge;
    return gpa.alloc(u8, n);
}
