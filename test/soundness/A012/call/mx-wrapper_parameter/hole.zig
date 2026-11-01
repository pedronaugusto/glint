// matrix: a size from input handed to the program's own wrapper, which allocates it
const std = @import("std");
fn buffer(gpa: std.mem.Allocator, len: usize) ![]u8 {
    return gpa.alloc(u8, len);
}
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    return buffer(gpa, try r.takeInt(u32, .little));
}
