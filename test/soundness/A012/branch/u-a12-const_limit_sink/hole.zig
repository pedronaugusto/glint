// A012: a number from input checked against the program's `const` limit on one path only: a
// peer chooses the size on the other.
const std = @import("std");
const max = 4096;
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, strict: bool) ![]u8 {
    const n = try r.takeInt(u32, .little);
    if (strict and n > max) return error.TooBig;
    return gpa.alloc(u8, n);
}
