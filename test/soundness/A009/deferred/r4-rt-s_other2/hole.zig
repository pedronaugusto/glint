// review 4: rt/s_other2.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !u8 {
    const input = try r.take(64);
    const copy = try gpa.alloc(u8, 8);
    defer gpa.free(copy);
    const pos = std.mem.indexOfScalar(u8, input, 0) orelse return error.Bad;
    return copy[pos];
}
