// glint-b: A005 call (helper): the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
fn drop(gpa: std.mem.Allocator, b: []u8) void {
    gpa.free(b);
}
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    drop(gpa, buffer);
    return Bytes.adopt(buffer, n);
}
