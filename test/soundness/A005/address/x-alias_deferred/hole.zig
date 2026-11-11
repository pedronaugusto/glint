// A005 address (alias, deferred): the allocation freed through an alias when the scope ends,
// after the adoption; the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    const p = &buffer;
    defer gpa.free(p.*);
    return Bytes.adopt(buffer, n);
}
