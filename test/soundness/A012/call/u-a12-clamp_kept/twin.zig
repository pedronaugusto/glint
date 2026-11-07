// A012: a number from input clamped to the program's limit on both branches, kept in a list and read
// back as a size: held where the list is given it, as a sink reads it (Proof.counts).
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = try r.takeInt(u32, .little);
    const m: u32 = if (n > 4096) 4096 else n;
    var sizes: std.ArrayList(u32) = .empty;
    defer sizes.deinit(gpa);
    try sizes.append(gpa, m);
    return gpa.alloc(u8, sizes.items[0]);
}
