// glint-b: A005 destructure (tuple): the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize, keep: *[]u8) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    var m: usize = 0;
    keep.*, m = .{ buffer, 1 };
    _ = &m;
    return Bytes.adopt(buffer, n);
}
