// glint-c: memory holding the peer's number is given back: a free sizes nothing, whatever the memory holds
const std = @import("std");
pub fn f(gpa: std.mem.Allocator, r: *std.Io.Reader) !void {
    const one = try gpa.create(u32);
    defer gpa.destroy(one);
    one.* = try r.takeInt(u32, .big);
    const out = try gpa.alloc(u8, 16);
    gpa.free(out);
}
