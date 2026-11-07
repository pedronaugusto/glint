// A012: a number from input "clamped" the wrong way (at least the program's limit, not at most it),
// kept in a list and read back as a size: a peer chooses it past the limit.
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = try r.takeInt(u32, .little);
    const m: u32 = if (n > 4096) n else 4096;
    var sizes: std.ArrayList(u32) = .empty;
    defer sizes.deinit(gpa);
    try sizes.append(gpa, m);
    return gpa.alloc(u8, sizes.items[0]);
}
