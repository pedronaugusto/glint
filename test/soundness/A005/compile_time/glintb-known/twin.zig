// glint-b: A005 compile_time (known): the same shape made safe, which must stay clean
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
const freeing = false;
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    if (comptime freeing) gpa.free(buffer);
    return Bytes.adopt(buffer, n);
}
