// matrix: a defer writes input through a pointer to the size at the block's exit
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: u32 = 64;
    const m = try r.takeInt(u32, .little);
    {
        const p = &n;
        defer p.* = m;
    }
    return gpa.alloc(u8, n);
}
