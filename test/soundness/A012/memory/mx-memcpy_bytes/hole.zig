// matrix: a peer's four bytes copied by @memcpy into the size's own bytes
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: u32 = 0;
    @memcpy(std.mem.asBytes(&n), try r.take(4));
    return gpa.alloc(u8, n);
}
