// glint-b: A005 field (named): the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
const Keep = struct { b: []u8 };
pub fn f(gpa: std.mem.Allocator, n: usize, k: *Keep) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    @field(k, "b") = buffer;
    return Bytes.adopt(buffer, n);
}
