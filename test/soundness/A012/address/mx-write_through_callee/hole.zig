// matrix: a callee writes input through the pointer it is given, the local then sizes the allocation
const std = @import("std");
fn readSize(out: *u32, r: *std.Io.Reader) !void {
    out.* = try r.takeInt(u32, .little);
}
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: u32 = 0;
    try readSize(&n, r);
    return gpa.alloc(u8, n);
}
