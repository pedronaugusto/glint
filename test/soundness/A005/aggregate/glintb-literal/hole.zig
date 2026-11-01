// glint-b: A005 aggregate (literal): the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, keep: *[1][]u8) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    keep.* = .{buffer};
    return Bytes.adopt(buffer, n);
}
