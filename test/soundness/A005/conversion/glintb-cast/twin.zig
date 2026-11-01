// glint-b: A005 conversion (cast): the same shape made safe, which must stay clean
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    @as([]u8, buffer)[0] = 0;
    return Bytes.adopt(buffer, n);
}
