// matrix A012 conversion: input's bytes reinterpreted by @bitCast as a u32 size an allocation
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const bytes = try r.takeArray(4);
    const n: u32 = @bitCast(bytes.*);
    return gpa.alloc(u8, n);
}
