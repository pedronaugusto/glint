// glint-b: A005 capture (value): the same shape made safe, which must stay clean
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, c: ?u8) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    if (c) |v| buffer[0] = v;
    return Bytes.adopt(buffer, n);
}
