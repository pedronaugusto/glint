// matrix A012 unwrap: an input read with a catch default
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = r.takeInt(u32, .little) catch 0;
    return gpa.alloc(u8, n);
}
