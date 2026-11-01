// glint-b: A005 unwrap (optional): the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const maybe: ?[]u8 = try gpa.alloc(u8, n);
    const buffer = maybe.?;
    gpa.free(maybe.?);
    return Bytes.adopt(buffer, n);
}
