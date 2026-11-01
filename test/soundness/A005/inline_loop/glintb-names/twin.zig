// glint-b: A005 inline_loop (names): the same shape made safe, which must stay clean
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    inline for (.{0}) |i| buffer[i] = 0;
    return Bytes.adopt(buffer, n);
}
