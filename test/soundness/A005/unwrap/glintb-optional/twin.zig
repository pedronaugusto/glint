// glint-b: A005 unwrap (optional): the same shape made safe, which must stay clean
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const maybe: ?[]u8 = try gpa.alloc(u8, n);
    const buffer = maybe.?;
    return Bytes.adopt(buffer, n);
}
