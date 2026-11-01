// matrix A012 call: a helper returns a size read from input
const std = @import("std");
fn size(r: *std.Io.Reader) !u32 {
    return r.takeInt(u32, .little);
}
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    return gpa.alloc(u8, try size(r));
}
