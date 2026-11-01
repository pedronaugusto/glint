// glint-b: A005 jump (break): the same shape made safe, which must stay clean
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, c: bool) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    blk: {
        if (c) break :blk;
        buffer[0] = 0;
    }
    return Bytes.adopt(buffer, n);
}
