// glint-b: A005 compile_time (known): the unsafe shape, which must flag
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
const freeing = true;
pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes {
    const buffer = try gpa.alloc(u8, n);
    if (comptime freeing) gpa.free(buffer);
    return Bytes.adopt(buffer, n);
}
