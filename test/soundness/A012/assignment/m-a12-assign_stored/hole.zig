// matrix A012 assignment: a size from input stored into a variable, then allocated
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: u32 = 0;
    n = try r.takeInt(u32, .little);
    return gpa.alloc(u8, n);
}
