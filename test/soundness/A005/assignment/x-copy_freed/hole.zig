// A005 assignment (copy freed): the allocation's first local freed after a copy of it is made,
// the copy adopted; the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const first = try gpa.alloc(u8, n);
    const buffer = first;
    gpa.free(first);
    return Bytes.adopt(buffer, n);
}
