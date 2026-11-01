// glint-b: A005 operator (binary): the same shape made safe, which must stay clean
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, a: bool, b: bool) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    if (a or b) buffer[0] = 0;
    return Bytes.adopt(buffer, n);
}
