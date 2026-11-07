// A012: a number from input checked against the program's `const` limit on one path only, then kept
// in a list and read back as a size: a peer chooses it on the other path.
const std = @import("std");
const max = 4096;
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, strict: bool) ![]u8 {
    const n = try r.takeInt(u32, .little);
    if (strict and n > max) return error.TooBig;
    var sizes: std.ArrayList(u32) = .empty;
    defer sizes.deinit(gpa);
    try sizes.append(gpa, n);
    return gpa.alloc(u8, sizes.items[0]);
}
