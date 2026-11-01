// glint-b: A005 jump (break): the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, c: bool) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    blk: {
        if (c) break :blk;
        gpa.free(buffer);
    }
    return Bytes.adopt(buffer, n);
}
