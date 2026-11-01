// matrix A012 assignment: the size stored is one a limit checked
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const m = try r.takeInt(u32, .little);
    if (m > 4096) return error.TooLarge;
    var n: u32 = 0;
    n = m;
    return gpa.alloc(u8, n);
}
