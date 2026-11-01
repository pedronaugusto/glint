// glint-b: A005 assignment (write): the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, keep: *[]u8) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    keep.* = buffer;
    return Bytes.adopt(buffer, n);
}
