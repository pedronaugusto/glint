// glint-b: A005 call (helper): the same shape made safe, which must stay clean
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
fn zero(b: []u8) void {
    @memset(b, 0);
}
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    zero(buffer);
    return Bytes.adopt(buffer, n);
}
