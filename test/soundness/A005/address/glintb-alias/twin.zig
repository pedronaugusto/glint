// glint-b: A005 address (alias): the same shape made safe, which must stay clean
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    const p = &buffer;
    p.*[0] = 0;
    return Bytes.adopt(buffer, n);
}
