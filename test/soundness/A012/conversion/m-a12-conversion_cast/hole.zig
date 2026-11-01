// matrix A012 conversion: an input u64 cast to the size
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = try r.takeInt(u64, .little);
    return gpa.alloc(u8, @intCast(n));
}
