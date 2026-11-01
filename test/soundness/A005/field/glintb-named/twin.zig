// glint-b: A005 field (named): the same shape made safe, which must stay clean
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
const Keep = struct { n: usize };
pub fn f(gpa: std.mem.Allocator, n: usize, k: *Keep) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    @field(k, "n") = buffer.len;
    return Bytes.adopt(buffer, n);
}
