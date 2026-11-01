// matrix A012 deferred: a defer overwrites the input size with a constant at the block's exit
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: u32 = 0;
    {
        defer n = 64;
        n = try r.takeInt(u32, .little);
    }
    return gpa.alloc(u8, n);
}
