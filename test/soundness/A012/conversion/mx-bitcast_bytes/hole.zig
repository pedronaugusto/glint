// matrix: a peer's four bytes made a size by @bitCast
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const bytes = try r.takeArray(4);
    const n: u32 = @bitCast(bytes.*);
    return gpa.alloc(u8, n);
}
