// glint-b: A005 operator (binary): the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, a: bool, b: bool) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    if (a or b) gpa.free(buffer);
    return Bytes.adopt(buffer, n);
}
