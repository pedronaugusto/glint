// glint-c: memory holding the peer's number is given back, and the number sizes an allocation before it: the allocation is found
const std = @import("std");
pub fn f(gpa: std.mem.Allocator, r: *std.Io.Reader) !void {
    const one = try gpa.create(u32);
    defer gpa.destroy(one);
    one.* = try r.takeInt(u32, .big);
    const out = try gpa.alloc(u8, one.*);
    gpa.free(out);
}
