// glint-b: A005 destructure (tuple): the same shape made safe, which must stay clean
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, keep: *usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    var m: usize = 0;
    keep.*, m = .{ buffer.len, 1 };
    _ = &m;
    return Bytes.adopt(buffer, n);
}
