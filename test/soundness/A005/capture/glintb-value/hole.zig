// glint-b: A005 capture (value): the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, c: ?u8) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    if (c) |_| gpa.free(buffer);
    return Bytes.adopt(buffer, n);
}
