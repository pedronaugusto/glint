// A012: a number from input checked against the program's `const` limit on every path, then kept in a
// list and read back as a size: held where the list is given it, as a sink reads it (Proof.counts).
const std = @import("std");
const max = 4096;
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = try r.takeInt(u32, .little);
    if (n > max) return error.TooBig;
    var sizes: std.ArrayList(u32) = .empty;
    defer sizes.deinit(gpa);
    try sizes.append(gpa, n);
    return gpa.alloc(u8, sizes.items[0]);
}
