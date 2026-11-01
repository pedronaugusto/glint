// glint-b: A005 memory (bytes): the same shape made safe, which must stay clean
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, keep: []u8) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    @memcpy(keep[0..n], buffer);
    return Bytes.adopt(buffer, n);
}
