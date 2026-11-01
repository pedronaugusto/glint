// matrix A012 deferred: a defer stores input into the size at the block's exit
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: u32 = 64;
    const m = try r.takeInt(u32, .little);
    {
        defer n = m;
    }
    return gpa.alloc(u8, n);
}
