// warp-fast: the same count, checked against the program's own limit before it sizes anything
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: u32 = 0;
    while (try r.takeByte() != 0) n += 1;
    if (n > 64) return error.TooMany;
    return gpa.alloc(u8, n);
}
