// glint-b: A005 deferred (defer): the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    defer gpa.free(buffer);
    return Bytes.adopt(buffer, n);
}
