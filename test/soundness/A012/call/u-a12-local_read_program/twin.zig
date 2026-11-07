// A012 in the program's own file: a size read from stdin, checked against the program's limit
// first: bounded by it.
const std = @import("std");
pub fn sizes(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var buf: [64]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &buf);
    const r = &fr.interface;
    const n = try r.takeInt(u32, .little);
    if (n > 4096) return error.TooBig;
    return gpa.alloc(u8, n);
}
